# Ollama Compatibility Shim

Ollama stores some models in a non-standard GGUF format that differs from
the canonical tensor layout the model's architecture expects. This document
describes the compatibility shim that detects those blobs -- translating
some in place, refusing others with a pointer to a properly-formatted
download -- and the load-time performance work done for the GB10 (DGX Spark).

## Background

Ollama downloads models as raw GGUF blobs and stores them in
`~/.ollama/models/blobs/`. For most models the blobs are standard GGUFs that
llama.cpp can load without any special handling. However, some models —
including `nemotron-3-super` — were originally converted with Ollama-specific
tensor naming conventions that do not match what the upstream architecture
code expects.

With the compat shim disabled (`OLLAMA_COMPAT_DISABLE=1`), loading the blob
directly produces a tensor shape mismatch deep in model loading:

```
error: tensor 'blk.1.ffn_down_exps.weight' has wrong shape
  expected: [n_ff_exp=2048, n_embd=4096, n_expert=64]
  got:      [n_ff_exp=2048, moe_latent_size=1024, n_expert=64]
```

The root cause is that `moe_latent_size` (1024) is not present in the
model's hyperparameters in an Ollama-format blob, so the model code falls
back to `n_embd` (4096) when computing the expected tensor dimension.

With the shim enabled (the default), this fingerprint is now caught early
and reported clearly instead -- see "Detection and current behavior" below.
This used to be fixed in place (see history below), but Unsloth now
publishes a standard-format conversion for every known latent-FFN Nemotron
model, so llama.cpp now refuses to load this layout rather than patching
it. Use the Unsloth GGUF (linked in
[nemotron-super-spark.md](nemotron-super-spark.md#gguf-source)) instead of
the Ollama blob.

## The Compat Shim

The shim lives in `src/llama-ollama-compat.cpp` and is compiled into
`libllama.so`. It runs during model metadata loading, before any tensors
are read.

### Detection and current behavior

`translate_metadata()` dispatches on the GGUF architecture string. For
`nemotron_h_moe` it calls `handle_nemotron_h_moe()`, which fingerprints the
blob by checking for the presence of `blk.1.ffn_latent_in` tensors (the
latent-FFN, Ollama-only case) or `mtp.*` tensors (present in some
otherwise-standard files) -- both are absent in a standard nemotron_h_moe
GGUF.

| Fingerprint | Result |
|---|---|
| `ffn_latent_in`/`out` tensors present | **Refuses to load**, with an error naming the Unsloth GGUF as the fix. There is no in-place translation for this case anymore (see history below). |
| Only `mtp.*` tensors present | Skips them silently and loads normally -- these are Multi-Token-Prediction tensors llama.cpp doesn't use, not a sign of a broken conversion. |

The shim is disabled by setting `OLLAMA_COMPAT_DISABLE=1` (this also
disables the `mtp.*` skip, so a file that needs it will fail to load with a
duplicate/unclaimed-tensor error instead).

### History: in-place translation (removed 2026-09-04)

The `ffn_latent_in`/`out` case used to be fixed in place: inject
`moe_latent_size` (derived from the latent tensor's shape) and rename the
tensors to `ffn_latent_down`/`up` (pure metadata/name edits -- this case
never needed a byte-level `LoadOp`, unlike a few other archs' handlers in
this same file). It was removed once a standard-format GGUF became
available for the model that motivated it (nemotron-3-super): with a
byte-correct source file on hand, silently patching a non-standard one adds
maintenance surface for no benefit, so the shim now refuses that layout and
points at the correct download instead.

### Testing without the real model

The latent-FFN case only exists in the largest Nemotron-3 tier (Super,
reportedly also Ultra) -- Nano and Cascade-2 have no latent tensors, so
there's no small real model that reproduces it. `tuned/fixtures/` has two
generators that build near-empty synthetic GGUFs (a few hundred bytes) that
only carry the fingerprint the detector checks for, no real weights:

```bash
python3 -m venv /tmp/fixture-venv && /tmp/fixture-venv/bin/pip install -r requirements.txt
PYTHONPATH=gguf-py /tmp/fixture-venv/bin/python3 \
  tuned/fixtures/make-nemotron-h-moe-latent-fixture.py /tmp/latent.gguf
build/bin/llama-cli -m /tmp/latent.gguf -p hi -n 1
# expect: a clean "...does not support loading this non-standard layout
# directly. Download a standard-format GGUF..." error and exit 1 -- not a
# crash, not a raw tensor-shape-mismatch error.

PYTHONPATH=gguf-py /tmp/fixture-venv/bin/python3 \
  tuned/fixtures/make-nemotron-h-moe-mtp-only-fixture.py /tmp/mtp-only.gguf
build/bin/llama-cli -m /tmp/mtp-only.gguf -p hi -n 1
# expect: the mtp tensor is skipped silently (no refusal message); it then
# fails for an unrelated reason (the fixture has no other hparams/tensors),
# confirming the two fingerprints are still handled independently.
```

### Hook sites

The shim is wired into `llama-model-loader.cpp` at three points:

- `translate_metadata()` — called after the GGUF arch string is read
- `should_skip_tensor()` — called in the tensor index loop
- `maybe_load_text_tensor()` — called in the data load path

## Load-Time Performance (GB10 / DGX Spark)

### Root cause

Loading an 80 GiB model on DGX Spark (GB10, CUDA IGPU with unified memory)
originally took **313 seconds** via the default mmap path.

llama.cpp calls `load_all_data` twice per model load:

1. **CPU context** (fit phase): `buffer_from_host_ptr = true` — the loader
   just stores a pointer into the mmap region. Completes in ~0 seconds.
2. **CUDA context** (real load): `buffer_from_host_ptr = false` (hardcoded
   in the CUDA backend). The loader allocates device memory and calls
   `ggml_backend_cuda_buffer_set_tensor` for every tensor — a synchronous
   `cudaMemcpyAsync` + `cudaStreamSynchronize` H2D copy per tensor. With
   ~5000 tensors loaded from cold mmap pages, this serialises storage I/O
   at ~259 MB/s.

### Fix

Passing `--no-mmap` switches the CUDA context to the `file+async-gpu` path:
four pinned 64 MB staging buffers with overlapped sequential `pread()` and
async GPU upload. This achieves ~1131 MB/s — a **4.4× speedup** — because
sequential NVMe reads with read-ahead are far more efficient than the
per-tensor random-access pattern that mmap produces.

| Mode | Time | Throughput |
|---|---|---|
| `mmap+direct` (default) | 313 s | 259 MB/s |
| `file+async-gpu` (`--no-mmap`) | **72 s** | **1131 MB/s** |
| `--no-mmap` + `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` | 106 s | 764 MB/s |

`GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` uses `cudaMallocManaged` for CUDA
allocations. On GB10 this regresses throughput; do not use it alongside
`--no-mmap`.

The fix is applied permanently in the Ollama model by adding
`PARAMETER use_mmap false` to the `nemotron-3-super` Modelfile.

### Long-term opportunity

`buffer_from_host_ptr` is hardcoded `false` in the CUDA backend even when
`prop.integrated > 0` (GB10 is detected as `GGML_BACKEND_DEVICE_TYPE_IGPU`).
On unified-memory hardware there is no physical copy needed — enabling
`buffer_from_host_ptr` via `cudaHostRegister` on the mmap region would
reduce load time to ~0 s at the cost of deferring storage I/O to the first
inference. This is not yet implemented.

## Instrumentation

`[TENSOR_LOAD]` progress markers are emitted via `fprintf(stderr, ...)` in
`llama-model-loader.cpp`. They must use `fprintf` rather than `LLAMA_LOG_INFO`
because the fit phase installs a custom log callback that demotes INFO below
the verbosity threshold, silently discarding `LLAMA_LOG_INFO` output.

```
[TENSOR_LOAD] starting, mode=file+async-gpu total=79.14 GiB
[TENSOR_LOAD] 14.0% (11.10/79.14 GiB) elapsed=10.6s
...
[TENSOR_LOAD] done: 79.14 GiB in 71.6 s (1131 MB/s)
```

The `mode` string reflects the actual load path:

| Mode string | Condition |
|---|---|
| `mmap+direct` | mmap + CPU backend (buffer_from_host_ptr) |
| `mmap+async-gpu` | mmap + GPU upload backend |
| `file+sync` | no-mmap + CPU backend |
| `file+async-gpu` | no-mmap + GPU upload backend |

## Files

| File | Purpose |
|---|---|
| `src/llama-ollama-compat.cpp` | Compat shim — arch dispatch and per-arch handlers |
| `src/llama-ollama-compat.h` | Public API: `translate_metadata`, `should_skip_tensor`, `maybe_load_text_tensor` |
| `src/llama-ollama-compat-util.cpp/h` | Shared utilities used by compat handlers |
| `src/llama-model-loader.cpp` | Hook sites + `[TENSOR_LOAD]` instrumentation |
| `src/CMakeLists.txt` | Adds compat sources to the `llama` library |
| `tools/mtmd/clip.cpp` | Vision model compat hook |
| `tools/mtmd/CMakeLists.txt` | Adds `src/` to the mtmd include path |
| `docs/gb10/nemotron-super-spark.md` | Model settings and launch flags reference |
| `tuned/fixtures/make-nemotron-h-moe-*.py` | Synthetic GGUF generators for testing the shim without a real model |

## Deploying with Ollama

See `scripts/deploy-local-llama-cpp.sh` in the Ollama repo
(`deploy-local-llama-cpp` branch). That script copies the build outputs from
this repo into `/usr/local/lib/ollama/local_llama_cpp/` and symlinks
`llama-server` so a stock Ollama installation uses this build.

Build this repo first:

```bash
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=121   # GB10 (Blackwell SM 12.1)
cmake --build build --config Release -j$(nproc)
```

Then deploy and restart:

```bash
cd /path/to/ollama
sudo systemctl stop ollama
sudo ./scripts/deploy-local-llama-cpp.sh
sudo systemctl daemon-reload
sudo systemctl start ollama
```

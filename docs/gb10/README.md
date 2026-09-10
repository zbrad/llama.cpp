# DGX Spark (GB10) with llama.cpp

This document covers building and running llama.cpp on NVIDIA's DGX Spark
(GB10 GPU, Blackwell SM 12.1), including the compat shim needed for
Ollama-format models and the load-time optimizations for the unified-memory
architecture.

## Hardware Overview

**Device**: NVIDIA GB10 (integrated GPU in DGX Spark)
- **Architecture**: Blackwell, SM 12.1 (`-DCMAKE_CUDA_ARCHITECTURES=121`)
- **Memory**: Unified address space (iGPU, ~120 GiB total)
- **Compute**: ~14 tok/s inference for nemotron-3-super at Q4_K_XL

## Building for Spark

```bash
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=121
cmake --build build --config Release -j$(nproc)
```

The build outputs go to `build/bin/`:

```
build/bin/llama-server          # main inference server
build/bin/llama-quantize        # quantization tool
build/bin/lib*.so.0.13.1        # shared libraries
```

## Ollama Compatibility Shim

Some models stored in Ollama's blob format use non-standard GGUF tensor
layouts that don't match the canonical architecture expectations. The compat
shim handles these transparently.

### The Problem

When loading `nemotron-3-super` from an Ollama-format blob without the shim:

```
error: tensor 'blk.1.ffn_down_exps.weight' has wrong shape
  expected: [n_ff_exp=2048, n_embd=4096, n_expert=64]
  got:      [n_ff_exp=2048, moe_latent_size=1024, n_expert=64]
```

The Ollama conversion used different tensor names and didn't inject
`moe_latent_size=1024` into the model metadata, so the loader falls back to
using `n_embd` (4096) instead of the correct projection dimension (1024).

### The Solution

The compat shim in `src/llama-ollama-compat.cpp` runs during metadata loading
and:

1. **Detects** Ollama-format blobs by fingerprinting: checking for `blk.1.ffn_latent_in` or `mtp.*` tensors
2. **Injects** `moe_latent_size=1024` into hyperparameters
3. **Renames** tensors: `ffn_latent_in` → `ffn_latent_down`, `ffn_latent_out` → `ffn_latent_up`
4. **Skips** multi-token prediction tensors (`mtp.*`)

The shim is wired into three call sites in `llama-model-loader.cpp`:
- `translate_metadata()` — after arch string is read
- `should_skip_tensor()` — in the tensor index loop
- `maybe_load_text_tensor()` — in the load path

Disable with `OLLAMA_COMPAT_DISABLE=1` if needed.

For full details, see [ollama-compat.md](ollama-compat.md).

## Load-Time Performance: 313s → 72s

### Root Cause Analysis

Loading an 80 GiB model originally took **313 seconds** on Spark. The
bottleneck was synchronous per-tensor copies from cold mmap pages.

llama.cpp calls `load_all_data` twice:

1. **CPU context** (fit phase): `buffer_from_host_ptr = true` — no copy, ~0s
2. **CUDA context** (real load): `buffer_from_host_ptr = false` (hardcoded) —
   allocates device memory and issues `cudaMemcpyAsync(H2D)` +
   `cudaStreamSynchronize` for each of ~5000 tensors from non-pinned mmap
   pages → ~259 MB/s (storage bandwidth)

The problem is architectural: the CUDA backend hardcodes `buffer_from_host_ptr=false`
even when `prop.integrated > 0` (Spark is detected as `GGML_BACKEND_DEVICE_TYPE_IGPU`).
On unified memory, no physical copy is needed — the CPU and GPU see the same
physical RAM.

### The Fix: --no-mmap

Passing `--no-mmap` switches to the `file+async-gpu` path:
- Four pinned 64 MB staging buffers
- Overlapped sequential `pread()` and async GPU upload
- Achieves ~1131 MB/s — a **4.4× speedup**

The fix is applied permanently in Ollama models by adding
`PARAMETER use_mmap false` to the Modelfile.

### Performance Results

| Mode | Time | Throughput |
|---|---|---|
| `mmap+direct` (default) | 313 s | 259 MB/s |
| `file+async-gpu` (`--no-mmap`) | **72 s** | **1131 MB/s** |
| `--no-mmap` + `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` | 106 s | 764 MB/s |

The unified-memory variant regresses; do not use it with `--no-mmap`.

### Long-Term Opportunity

Enabling `buffer_from_host_ptr=true` for CUDA when `prop.integrated > 0` via
`cudaHostRegister` would reduce load time to ~0s at the cost of deferring
storage I/O to first inference (page faults). This is not yet implemented but
would be the ideal solution for unified-memory systems.

## Instrumentation

`[TENSOR_LOAD]` progress markers help diagnose load behavior:

```
[TENSOR_LOAD] starting, mode=file+async-gpu total=79.14 GiB
[TENSOR_LOAD] 14.0% (11.10/79.14 GiB) elapsed=10.6s
...
[TENSOR_LOAD] done: 79.14 GiB in 71.6 s (1131 MB/s)
```

These are emitted via `fprintf(stderr, ...)` in `llama-model-loader.cpp` —
`LLAMA_LOG_INFO` would be silently filtered by the fit-phase log callback.

## Nemotron-3-Super Model Settings

**Model**: nvidia/nemotron-3-super-120b-a12b
- **Architecture**: Hybrid Latent MoE — 120B total, 12B active
- **Context**: up to 1M tokens (use 262144 safely for single-GPU)
- **Quantization**: Q4_K_XL (~65 GB) recommended for Spark
- **Performance**: ~14 tok/s at Q4_K_XL with `--n-gpu-layers 99`

### Launch Example

```bash
/path/to/llama-server \
  --model nemotron-3-super.Q4_K_XL.gguf \
  --ctx-size 262144 \
  --n-gpu-layers 99 \
  --threads 8 \
  --temp 0.6 --top-p 0.95 --min-p 0.01 \
  --special --verbose-prompt
```

For more model details and options, see [nemotron-super-spark.md](nemotron-super-spark.md).
For the smaller Nano sibling (better fit when sharing GPU memory with other
workloads), see [nemotron-nano-gb10.md](nemotron-nano-gb10.md).

## Deploying with Ollama

To use this build with Ollama, see [local-llama-cpp.md](../../ollama/docs/local-llama-cpp.md)
in the Ollama repo (or run `scripts/deploy-local-llama-cpp.sh` from an Ollama
checkout that has the `deploy-local-llama-cpp` branch).

Quick summary:

```bash
cd /path/to/ollama
sudo systemctl stop ollama
sudo ./scripts/deploy-local-llama-cpp.sh
sudo systemctl daemon-reload
sudo systemctl start ollama
```

This copies the build to `/usr/local/lib/ollama/local_llama_cpp/` and symlinks
`/usr/local/lib/ollama/llama-server` to use it.

## Implementation Details

### Files Modified / Added

| File | Purpose |
|---|---|
| `src/llama-ollama-compat.cpp/h` | Compat shim — arch dispatch and handlers |
| `src/llama-ollama-compat-util.cpp/h` | Shared compat utilities |
| `src/llama-model-loader.cpp` | Hook sites + `[TENSOR_LOAD]` instrumentation |
| `src/CMakeLists.txt` | Adds compat sources to `llama` library |
| `tools/mtmd/clip.cpp` | Vision model compat hook |
| `tools/mtmd/CMakeLists.txt` | Adds `src/` to mtmd include path |

### Key Branches

- **`spark-build`**: Working branch with compat shim, instrumentation, and docs
- **`deploy-local-llama-cpp`** (in Ollama): Deploy script and integration docs

## References

- [ollama-compat.md](ollama-compat.md) — Detailed compat shim design and rationale
- [nemotron-super-spark.md](nemotron-super-spark.md) — Model-specific launch flags and quantization options
- [nemotron-nano-gb10.md](nemotron-nano-gb10.md) - Nano sibling: launch flags, sampling, systemd example
- [local-llama-cpp.md](../../ollama/docs/local-llama-cpp.md) (Ollama repo) — When and how to use a local llama.cpp build with Ollama
- NVIDIA DGX Spark guide: https://build.nvidia.com/spark/llama-cpp/overview
- Nemotron-3-Super model card: https://build.nvidia.com/nvidia/nemotron-3-super-120b-a12b/modelcard

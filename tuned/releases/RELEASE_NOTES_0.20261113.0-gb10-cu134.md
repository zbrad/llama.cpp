## Install

The toolkit is part of the release name: `-cu133` is built with CUDA 13.3, `-cu134` with CUDA 13.4. Set `CUDA_TAG` once and
every command below follows it. This note is for **cu134**; to use the cu133 release set `CUDA_TAG=cu133` (it has its own note and tarball).

The one-line installer picks a toolkit for you: it reads the host CUDA version (`nvcc`, else `nvidia-smi`), looks for an exact `-cuNNN` release, and otherwise falls back to the newest
release with the same CUDA major (DGX OS reports 13.0, so it normally falls back). **To get cu134 regardless of the host, name it:**

```
# default install directory: ${XDG_DATA_HOME:-~/.local/share}/llmsrv  (use --dir to change)
CUDA_TAG=cu134
curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh \
  | LLAMA_CPP_CUDA_VERSION=13.4 bash -s -- --dir ~/llama-cpp-${CUDA_TAG}

# or pin the exact release instead of a toolkit:
curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh \
  | LLAMA_CPP_TAG=v0.20261113.0-gb10-${CUDA_TAG} bash
```

- **Path:** the installer prints the exact command to run the server at the end. With `--dir ~/llama-cpp-cu134` the server is `~/llama-cpp-cu134/llama-server-tuned`.
- **Run:** the libraries need `libcudart.so.13` and `libcublas.so.13` from any CUDA 13.x install, and `libcuda.so.1` from the driver.
- **Needs:** aarch64, GB10 (SM 12.1), driver R580 or newer.

## Components

| Component | Shipped file | Device code | Tests | Result |
|---|---|---|---|---|
| llama.cpp server and quantize | `llama-server-tuned`, `llama-quantize-tuned` | no | ctest, 72 tests (all labels: main, model, python) | 100% passed, 0 failed |
| ggml CUDA backend | `libggml-cuda-gb10-cu134.so` | yes (sm_121a) | ctest | passed |
| ggml and llama libraries | `libggml-gb10-cu134.so`, `libllama-gb10-cu134.so`, `libllama-server-impl-gb10-cu134.so`, others | no (name variant because they need the CUDA backend) | ctest | passed |
| ggml base and CPU | `libggml-base-cu134.so`, `libggml-cpu-cu134.so` | no | ctest | passed |
| NCCL 2.32.3 | static, inside `libggml-cuda` (from zbrad/nccl `v0.20261018.0-gb10-cu134`) | n/a (inside libggml-cuda) | multi-GPU not exercised (single GB10) | no `libnccl.so` shipped or needed |
| Web UI | `llama-ui-tuned-20261113`, embedded in `llama-server-tuned` | no | bundle audit gate (high), `check-ui.sh` (embedded assets byte-identical to the tarball, built from this tree's `tools/ui`) | passed |
| Package as installed | `llama-cpp-0.20261113.0-gb10-cu134.tar.gz` | | smoke: installed with `install.sh`, completion from a ~1 MB model, version stamp, libraries resolve inside the install directory | passed |

## About this build

llama-server-tuned + llama-quantize-tuned + 17 shared libraries, single-arch (sm_121a), built against CUDA 13.4. Includes the Ollama-format GGUF compatibility shim. Web UI: llama-ui-tuned-20261113 (audited dependency set, tarball sha256 a19ca0b4a602867486d82633e8d756c8ab0836cba42d2ef8370627db56a3a462). Easiest setup: curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash -- fetches this release, models/aliases.json, and llmsrv.sh for you (that URL always has the current installer; it takes the helper files from this release's own tag). To deploy into an Ollama installation instead, see zbrad/ollama's tuned-builds fetch script, or manually: extract and copy llama-server + libs to your Ollama lib directory, symlinking llama-server into place (see zbrad/ollama's docs/local-llama-cpp.md).

NCCL 2.32.3: from zbrad/nccl v0.20261018.0-gb10-cu134, built for cu134, linked statically into libggml-cuda; no libnccl.so is shipped or needed.

**This release: upstream llama.cpp v1.0.0.** Merged from ggml-org's `v1.0.0` tag (689 upstream commits not previously on the `tuned-builds` branch). `llama-server-tuned --version` reports `1.0.0-dev`. The release tag keeps the fork's date scheme (`v0.<date>.<seq>-<variant>-<cuda>`); it does not follow upstream's version number. Changes that can affect an existing setup, from upstream's v1.0.0 release notes:

- **Removed:** `--defrag-thold`, `llama_set_warmup` and 35 deprecated `llama.h` functions; `clip.h` (merged into `mtmd`). `llmsrv.sh` and `models.ini` use none of them.
- **Server security defaults:** server tools, MCP servers and the MCP proxy on a non-loopback address now need an API key unless `--allow-unauthenticated-tools` is given; media URLs (`image_url`) that point at local or private addresses are refused unless `--media-allow-private-urls` is given. `llmsrv.sh` enables no tools; a client that sends images by private-network URL (for example a LAN-hosted Open WebUI passing its own file URLs) needs the second flag.
- **Web UI:** upstream's redesigned UI (chat groups, markdown editor), built by llama-ui-tuned with dependency overrides `@modelcontextprotocol/sdk` 1.32.1, `dompurify` 3.4.17, `fast-uri` 3.1.8, `katex` 0.18.11, `mermaid` 11.17.2, `zod` 4.6.7 (`zod` 4.4.3 from upstream's lockfile is in GHSA-mrhx-c7xc-m3w5, high). Bundled packages with lower-severity advisories remain: `fast-uri` 3.1.8 and `ajv` (moderate), `@sveltejs/kit`, `bits-ui`, `runed`, `svelte-toolbelt` (low).
- **New:** FP8 KV caches (`-ctk/-ctv f8_e4m3`), host-memory MoE expert cache, `/v1/audio/speech`.

**Ollama compatibility shim:** upstream removed `tools/mtmd/clip.cpp`; the shim's two vision-side hooks (metadata translation and the tensor-load override) moved to the same points in `tools/mtmd/mtmd-model.cpp`. Checked on this build with Ollama's single-file `qwen3-vl:2b` (model blob `sha256:ebabfa59...`, used as both model and mmproj): with the shim the vision translation runs and the model describes `tools/mtmd/test-1.jpeg` correctly; with the shim disabled (`OLLAMA_LLAMA_CPP_COMPAT=0`) the same file fails to load. The documented `nemotron_h_moe` fixture checks (docs/gb10/ollama-compat.md) behave as expected.

Tested: the full ctest suite passed on this build, 72/72 (log attached), including upstream's new converter tests (`test-conversion-fp8`, `test-kv-cache-scales`), which now run in a test venv with upstream's converter requirements (torch 2.11.0+cpu, Python 3.14). The tarball was checked as extracted (version, ldd, RUNPATH, toolkit libraries) and installed with `install.sh` into a scratch directory, which served a completion. Not tested on this release: an R580 driver (only 620.70.06), and a full-size model.

### CUDA / driver compatibility

- **Built with:** CUDA 13.4.
- **Minimum driver:** R580 (>= 580). CUDA 13.x applications run on any driver from that branch on; see "CUDA minor version compatibility" in NVIDIA's [CUDA toolkit release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html).
- Features introduced after CUDA 13.0 need newer driver branches. Ones this build uses: none. CUDA 13.4 FP8-to-BF16 conversions (`CUDART_VERSION >= 13040`) are compiled into the cubin and need no newer driver.
- **GPU code:** cubin for sm_121a (224 modules) plus PTX. Runs only on that GPU; the driver loads the cubin directly, so nothing is JIT-compiled at load.
- **Host libraries required:** `libcublasLt.so.13`, `libcublas.so.13`, `libcudart.so.13` from any CUDA 13.x install (DGX OS ships 13.0). `libcuda.so.1` comes with the NVIDIA driver.
- **Tested on (driver):**
  - 580.178.04, tested with v10931-gb10-cu133: DGX OS 7.6.0, kernel 7.0.0-1019-nvidia, host CUDA 13.0 runtime; 38 GB GGUF fully on GPU (-ngl 99), completions served
  - 610.57.04, tested with v10931-gb10-cu133: same environment and result; this driver branch has a separate memory leak, unrelated to llama.cpp
  - 615.71.09, tested with v10931-gb10-cu133: same environment and result
  - 620.70.06, tested with v0.20261113.0-gb10-cu134: DGX OS 7.6.0, kernel 7.0.0-1025-nvidia (open kernel module); full ctest suite 72/72 passed (llama.cpp v1.0.0 merge, 2026-11-13)

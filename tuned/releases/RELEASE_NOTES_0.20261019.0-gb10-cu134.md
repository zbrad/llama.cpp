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
  | LLAMA_CPP_TAG=v0.20261019.0-gb10-${CUDA_TAG} bash
```

- **Path:** the installer prints the exact command to run the server at the end. With `--dir ~/llama-cpp-cu134` the server is `~/llama-cpp-cu134/llama-server-tuned`.
- **Run:** the libraries need `libcudart.so.13` and `libcublas.so.13` from any CUDA 13.x install, and `libcuda.so.1` from the driver.
- **Needs:** aarch64, GB10 (SM 12.1), driver R580 or newer.

## Components

| Component | Shipped file | Device code | Tests | Result |
|---|---|---|---|---|
| llama.cpp server and quantize | `llama-server-tuned`, `llama-quantize-tuned` | no | ctest, 61 tests | 100% passed, 0 failed |
| ggml CUDA backend | `libggml-cuda-gb10-cu134.so` | yes (sm_121a) | ctest | passed |
| ggml and llama libraries | `libggml-gb10-cu134.so`, `libllama-gb10-cu134.so`, `libllama-server-impl-gb10-cu134.so`, others | no (name variant because they need the CUDA backend) | ctest | passed |
| ggml base and CPU | `libggml-base-cu134.so`, `libggml-cpu-cu134.so` | no | ctest | passed |
| NCCL 2.32.3 | static, inside `libggml-cuda` (from zbrad/nccl `v0.20261018.0-gb10-cu134`) | n/a (inside libggml-cuda) | multi-GPU not exercised (single GB10) | no `libnccl.so` shipped or needed |
| Package as installed | `llama-cpp-0.20261019.0-gb10-cu134.tar.gz` | | smoke: installed with `install.sh`, version stamp, libraries resolve inside the install directory | passed |

## About this build

llama-server-tuned + llama-quantize-tuned + 17 shared libraries, single-arch (sm_121a), built against CUDA 13.4. Includes the Ollama-format GGUF compatibility shim. Web UI: llama-ui-tuned-20261016 (audited dependency set, tarball sha256 3dcb9b0bf7649069389108f92ed4911897076c8875ea0dae4b207cc072cf6804). Easiest setup: curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash -- fetches this release, models/aliases.json, and llmsrv.sh for you (that URL always has the current installer; it takes the helper files from this release's own tag). To deploy into an Ollama installation instead, see zbrad/ollama's tuned-builds fetch script, or manually: extract and copy llama-server + libs to your Ollama lib directory, symlinking llama-server into place (see zbrad/ollama's docs/local-llama-cpp.md).

NCCL 2.32.3: from zbrad/nccl v0.20261018.0-gb10-cu134, built for cu134, linked statically into libggml-cuda; no libnccl.so is shipped or needed.

**This release:** shared objects carry their axes: `libggml-cuda-gb10-cu134.so` (device code) and the libraries that need it (including `libggml-gb10-cu134.so`, `libllama-gb10-cu134.so`, `libllama-server-impl-gb10-cu134.so`) name variant and toolkit; the rest (`libggml-base-cu134.so`, `libggml-cpu-cu134.so`, ...) name the toolkit only. Build outputs now live in `tuned/build/cu134/`. Supersedes `v0.20261016.1-gb10-cu134` (earlier shared-object names). NCCL moves from 2.30.7 to 2.32.3.

Tested: the ctest suite passed on this build (log attached), and the tarball was checked as extracted (version, ldd, RUNPATH, toolkit libraries).

### CUDA / driver compatibility

- **Built with:** CUDA 13.4.
- **Minimum driver:** R580 (>= 580). CUDA 13.x applications run on any driver from that branch on; see "CUDA minor version compatibility" in NVIDIA's [CUDA toolkit release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html).
- Features introduced after CUDA 13.0 need newer driver branches. Ones this build uses: none.
- **GPU code:** cubin for sm_121a (221 modules) plus PTX. Runs only on that GPU; the driver loads the cubin directly, so nothing is JIT-compiled at load.
- **Host libraries required:** `libcublas.so.13`, `libcudart.so.13` from any CUDA 13.x install (DGX OS ships 13.0). `libcuda.so.1` comes with the NVIDIA driver.
- **Tested on (driver):**
  - 580.178.04, tested with v10931-gb10-cu133: DGX OS 7.6.0, kernel 7.0.0-1019-nvidia, host CUDA 13.0 runtime; 38 GB GGUF fully on GPU (-ngl 99), completions served
  - 610.57.04, tested with v10931-gb10-cu133: same environment and result; this driver branch has a separate memory leak, unrelated to llama.cpp
  - 615.71.09, tested with v10931-gb10-cu133: same environment and result

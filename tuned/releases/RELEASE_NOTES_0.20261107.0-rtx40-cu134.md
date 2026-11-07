llama-server-tuned + llama-quantize-tuned + 17 shared libraries, single-arch (sm_89), built against CUDA 13.4. Includes the Ollama-format GGUF compatibility shim. Web UI: llama-ui-tuned-20261016 (audited dependency set, tarball sha256 3dcb9b0bf7649069389108f92ed4911897076c8875ea0dae4b207cc072cf6804). Easiest setup: curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash -- fetches this release, models/aliases.json, and llmsrv.sh for you (that URL always has the current installer; it takes the helper files from this release's own tag). To deploy into an Ollama installation instead, see zbrad/ollama's tuned-builds fetch script, or manually: extract and copy llama-server + libs to your Ollama lib directory, symlinking llama-server into place (see zbrad/ollama's docs/local-llama-cpp.md).

NCCL 2.32.3: from zbrad/nccl v0.20261107.0-rtx40-cu134, built for cu134, linked statically into libggml-cuda; no libnccl.so is shipped or needed.

Tested: the ctest suite passed on this build (log attached), and the tarball was checked as extracted (version, ldd, RUNPATH, toolkit libraries).

### CUDA / driver compatibility

- **Built with:** CUDA 13.4.
- **Minimum driver:** R580 (>= 580). CUDA 13.x applications run on any driver from that branch on; see "CUDA minor version compatibility" in NVIDIA's [CUDA toolkit release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html).
- Features introduced after CUDA 13.0 need newer driver branches. Ones this build uses: none.
- **GPU code:** cubin for sm_89 (221 modules) plus PTX. Runs only on that GPU; the driver loads the cubin directly, so nothing is JIT-compiled at load.
- **Host libraries required:** `libcublas.so.13`, `libcudart.so.13` from any CUDA 13.x install. `libcuda.so.1` comes with the NVIDIA driver.
- **Tested on (driver):**
  - 621.14 (Windows host driver, through WSL2 Ubuntu 24.04), RTX 4090, tested with this release: the ctest suite and the smoke test (install.sh from the tarball, a completion served from a ~1 MB test model). Full-size model, same driver, after release: Qwen3-30B-A3B Q4_K_M (18.6 GB GGUF) fully on GPU (-ngl 99, 16k context), chat completions served at ~233 tok/s generation.

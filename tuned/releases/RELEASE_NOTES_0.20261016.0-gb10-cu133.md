<!-- DRAFT — not yet published: review, then delete this line and commit -->
llama-server-tuned + llama-quantize-tuned + 18 shared libraries, single-arch (sm_121a), built against CUDA 13.3. Includes the Ollama-format GGUF compatibility shim. Web UI: llama-ui-tuned-20261011 (audited dependency set, tarball sha256 98b185045268107b16d8eaf7c10045758bb0a4869da93f4e983765ec4f08e8d8). Easiest setup: curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash -- fetches this release, models/aliases.json, and llmsrv.sh for you (that URL always has the current installer; install.sh itself defaults to a pinned tuning-vN tag internally, see its own header). To deploy into an Ollama installation instead, see zbrad/ollama's tuned-builds fetch script, or manually: extract and copy llama-server + libs to your Ollama lib directory, symlinking llama-server into place (see zbrad/ollama's docs/local-llama-cpp.md).

Tested: the ctest suite passed on this build (log attached), and the tarball was checked as extracted (version, ldd, RUNPATH, toolkit libraries).

### CUDA / driver compatibility

- **Built with:** CUDA 13.3.
- **Minimum driver:** R580 (>= 580). CUDA 13.x applications run on any driver from that branch on; see "CUDA minor version compatibility" in NVIDIA's [CUDA toolkit release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html).
- Features introduced after CUDA 13.0 need newer driver branches. Ones this build uses: none.
- **GPU code:** cubin for sm_121a (144 modules) plus PTX. Runs only on that GPU; the driver loads the cubin directly, so nothing is JIT-compiled at load.
- **Host libraries required:** `libcublas.so.13`, `libcudart.so.13` from any CUDA 13.x install (DGX OS ships 13.0). `libcuda.so.1` comes with the NVIDIA driver.
- **Tested on (driver):**
  - 580.178.04, tested with v10931-gb10-cu133: DGX OS 7.6.0, kernel 7.0.0-1019-nvidia, host CUDA 13.0 runtime; 38 GB GGUF fully on GPU (-ngl 99), completions served
  - 610.57.04, tested with v10931-gb10-cu133: same environment and result; this driver branch has a separate memory leak, unrelated to llama.cpp
  - 615.71.09, tested with v10931-gb10-cu133: same environment and result

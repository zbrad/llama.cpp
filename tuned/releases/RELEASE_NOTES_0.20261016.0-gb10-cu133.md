llama-server-tuned + llama-quantize-tuned + 18 shared libraries, single-arch (sm_121a), built against CUDA 13.3. Includes the Ollama-format GGUF compatibility shim. Web UI: llama-ui-tuned-20261011 (audited dependency set, tarball sha256 98b185045268107b16d8eaf7c10045758bb0a4869da93f4e983765ec4f08e8d8). Easiest setup: curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash -- fetches this release, models/aliases.json, and llmsrv.sh for you (that URL always has the current installer; it takes the helper files from this release's own tag). To deploy into an Ollama installation instead, see zbrad/ollama's tuned-builds fetch script, or manually: extract and copy llama-server + libs to your Ollama lib directory, symlinking llama-server into place (see zbrad/ollama's docs/local-llama-cpp.md).

### What is new since `v10931-gb10-cu133` (2026-09-10)

- **Base:** upstream llama.cpp `master` at `b11191` (2026-09-25, declares `0.5.0-dev`) plus this fork's changes. Upstream has moved on: its latest stable release is `v0.7.0` (2026-10-15), and `master` is 502 commits ahead of this build (checked 2026-10-16).
- **Names:** the binaries are `llama-server-tuned` and `llama-quantize-tuned`, and every shared library has a unique `-tuned` file name and SONAME (for example `libggml-tuned.so.0`), so a stock llama.cpp installed beside this one cannot swap libraries with it in either direction. `install.sh` symlinks the `-tuned` names onto `~/.local/bin`.
- **Identity:** the release is `v0.<UTC date>.<seq>-gb10-cu133`. `llama-server --version` prints a `release:` line above upstream's `version:` line; the commit count in that line (`build N`) is this fork's history count, not upstream's. Every shipped `llama-server-tuned` and `libggml-cuda` carries one line of JSON build info (`readelf -p .tuned_build_info`, or `BUILD_INFO.json` in the install directory).
- **Web UI:** built from the audited `llama-ui-tuned` dependency set, and checked byte for byte against the files embedded in the server before packaging.
- **Installer and launcher:** `install.sh` verifies the checksum, that every library resolves and that a CUDA device is seen, and serves a completion from a ~1 MB model; it takes `--models-dir` and `--hf-cache`. `llmsrv.sh` searches configured model paths and the Hugging Face cache, and enables slot saving for chat export.
- **CUDA 13.3** (nvcc 13.3.73); single-arch `sm_121a`.

Tested: the ctest suite passed on this build, 62 of 62 tests across all labels (log attached). The tarball was checked as extracted (version, ldd, RUNPATH, toolkit libraries) and then installed with `install.sh` from the local package, which verified its checksum, that every library resolves, that a CUDA device is seen, and a served completion (log attached).

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

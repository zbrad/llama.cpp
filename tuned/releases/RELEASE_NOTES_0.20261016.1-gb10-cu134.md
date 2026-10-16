llama-server-tuned + llama-quantize-tuned + 17 shared libraries, single-arch (sm_121a), built against CUDA 13.4. Includes the Ollama-format GGUF compatibility shim. Web UI: llama-ui-tuned-20261016 (audited dependency set, tarball sha256 3dcb9b0bf7649069389108f92ed4911897076c8875ea0dae4b207cc072cf6804). Easiest setup: curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash -- fetches this release, models/aliases.json, and llmsrv.sh for you (that URL always has the current installer; it takes the helper files from this release's own tag). To deploy into an Ollama installation instead, see zbrad/ollama's tuned-builds fetch script, or manually: extract and copy llama-server + libs to your Ollama lib directory, symlinking llama-server into place (see zbrad/ollama's docs/local-llama-cpp.md).

### What is new since `v0.20261016.0-gb10-cu133`

- **CUDA 13.4** (nvcc 13.4.92), single-arch `sm_121a`. This is the first cu134 release of this fork.
- **Base:** upstream llama.cpp `v0.7.0` (2026-10-15), merged into this fork: 478 upstream commits over the cu133 release's base (`b11191`, 2026-09-25). The version it reports is `0.7.0-dev`. Upstream `master` is a further 25 commits ahead (checked 2026-10-16).
- **NCCL:** 2.30.7 from `zbrad/nccl v0.20261012.0-gb10-cu134`, built for CUDA 13.4 and linked statically into `libggml-cuda`. No `libnccl.so` is shipped or needed, and NCCL's symbols are hidden from the dynamic table. The cu133 release instead bundles the host's `libnccl2 2.31.2` (built for 13.3); that is why this package is 190 MB where the cu133 one is 605 MB.
- **Web UI:** rebuilt from upstream's new `tools/ui` as `llama-ui-tuned-20261016` (165 bundled packages; the audit gate at `high` passed), and checked byte for byte against the files embedded in the server before packaging.
- Same as the cu133 release: the `-tuned` binary and library names, the `release:` line in `--version`, the JSON build info (`BUILD_INFO.json`), the Ollama-format GGUF compatibility shim, `install.sh` and `llmsrv.sh`. Installing: `curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash` picks this release on a CUDA 13.4 host and falls back to cu133 on 13.3.

NCCL 2.30.7: from zbrad/nccl v0.20261012.0-gb10-cu134, built for cu134, linked statically into libggml-cuda; no libnccl.so is shipped or needed.

Tested: the ctest suite passed on this build, 61 of 61 tests across all labels, including the fork's Ollama-compat tests against upstream `v0.7.0` (log attached). The tarball was checked as extracted (version, ldd, RUNPATH, toolkit libraries, no libnccl) and then installed with `install.sh` from the local package, which verified its checksum, that every library resolves, that a CUDA device is seen, and a served completion (log attached). NCCL communication itself is not exercised: the test node has one GPU.

### CUDA / driver compatibility

- **Built with:** CUDA 13.4.
- **Minimum driver:** R580 (>= 580). CUDA 13.x applications run on any driver from that branch on; see "CUDA minor version compatibility" in NVIDIA's [CUDA toolkit release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html).
- Features introduced after CUDA 13.0 need newer driver branches. Ones this build uses: none.
- **GPU code:** cubin for sm_121a (183 modules) plus PTX. Runs only on that GPU; the driver loads the cubin directly, so nothing is JIT-compiled at load.
- **Host libraries required:** `libcublas.so.13`, `libcudart.so.13` from any CUDA 13.x install (DGX OS ships 13.0). `libcuda.so.1` comes with the NVIDIA driver.
- **Tested on (driver):**
  - 580.178.04, tested with v10931-gb10-cu133: DGX OS 7.6.0, kernel 7.0.0-1019-nvidia, host CUDA 13.0 runtime; 38 GB GGUF fully on GPU (-ngl 99), completions served
  - 610.57.04, tested with v10931-gb10-cu133: same environment and result; this driver branch has a separate memory leak, unrelated to llama.cpp
  - 615.71.09, tested with v10931-gb10-cu133: same environment and result

llama-server-tuned + llama-quantize-tuned + 17 shared libraries, single-arch (sm_89), built against CUDA 13.4. Includes the Ollama-format GGUF compatibility shim. Web UI: llama-ui-tuned-20261115 (audited dependency set, tarball sha256 eabd2485d0e9be98e652d246c07fdb2da90594fb74cdbab0a3b7f0d128b4d353). Easiest setup: curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash -- fetches this release, models/aliases.json, and llmsrv.sh for you (that URL always has the current installer; it takes the helper files from this release's own tag). To deploy into an Ollama installation instead, see zbrad/ollama's tuned-builds fetch script, or manually: extract and copy llama-server + libs to your Ollama lib directory, symlinking llama-server into place (see zbrad/ollama's docs/local-llama-cpp.md).

NCCL 2.32.3: from zbrad/nccl v0.20261107.0-rtx40-cu134, built for cu134, linked statically into libggml-cuda; no libnccl.so is shipped or needed.

**This release: web UI security update.** Same llama.cpp source (upstream v1.0.0) and the same NCCL as `v1.0.0-20261114.0-rtx40-cu134`; the build commit adds only build tooling (tuned-common syncs, a gb10 cu133 NCCL pin) and notes. The embedded web UI is llama-ui-tuned-20261115, which raises two dependency overrides:

- `fast-uri` 3.1.8 -> 3.1.9: GHSA-w74x-v6f9-j3xg and GHSA-wjr9-j795-jxcr (moderate), GHSA-xhq7-xmqj-769h and GHSA-333x-w4r6-6crp (low).
- `@sveltejs/kit` 2.70.2 -> 2.70.4: GHSA-mw6w-2fmv-pvw3 (moderate).

Bundled packages with advisories that remain are all low: `@sveltejs/kit` (GHSA-pfhg-q3qv-9q6r and GHSA-27mw-82g8-phjj, fixed only in kit 3.0.0), `bits-ui`, `runed`, `svelte-toolbelt`. `ajv`, listed as moderate in the previous notes, is no longer flagged.

Tested: the full ctest suite passed on this build, 72/72 (log attached). The tarball was checked as extracted (version, ldd, RUNPATH, toolkit libraries) and installed with `install.sh` into a scratch directory, which served a completion. Full-size model on the shipped llama-server-tuned, RTX 4090: Qwen3-30B-A3B Q4_K_M (18.6 GB GGUF) fully on GPU (-ngl 99, 16k ctx), completions at ~233 tok/s (llama-bench tg128 257 tok/s, build tree). Ollama compatibility shim, checked on the shipped llama-server-tuned with Ollama's single-file `qwen3-vl:2b` (model blob `sha256:ebabfa59...`, used as both model and mmproj): with the shim a chat completion describes `tools/mtmd/test-1.jpeg` correctly; with `OLLAMA_LLAMA_CPP_COMPAT=0` the same file fails to load. Not tested on this release: a native Linux host or an R580 driver.

### CUDA / driver compatibility

- **Built with:** CUDA 13.4.
- **Minimum driver:** R580 (>= 580). CUDA 13.x applications run on any driver from that branch on; see "CUDA minor version compatibility" in NVIDIA's [CUDA toolkit release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html).
- Features introduced after CUDA 13.0 need newer driver branches. Ones this build uses: none. CUDA 13.4 FP8-to-BF16 conversions (`CUDART_VERSION >= 13040`) are compiled into the cubin and need no newer driver.
- **GPU code:** cubin for sm_89 (224 modules) plus PTX. Runs only on that GPU; the driver loads the cubin directly, so nothing is JIT-compiled at load.
- **Host libraries required:** `libcublas.so.13`, `libcublasLt.so.13`, `libcudart.so.13` from any CUDA 13.x install. `libcuda.so.1` comes with the NVIDIA driver.
- **Tested on (driver):**
  - 621.14, tested with v1.0.0-20261115.0-rtx40-cu134: Windows host driver through WSL2 Ubuntu 24.04, RTX 4090; ctest suite 72/72, smoke test, Ollama vision shim check; Qwen3-30B-A3B Q4_K_M fully on GPU, completions at ~233 tok/s
  - 621.14, tested with v0.20261107.0-rtx40-cu134: Windows host driver through WSL2 Ubuntu 24.04, RTX 4090; ctest suite and smoke test (completion from a ~1 MB test model); Qwen3-30B-A3B Q4_K_M (18.6 GB GGUF) fully on GPU (-ngl 99, 16k ctx), completions served at ~233 tok/s

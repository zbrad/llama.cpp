#!/bin/bash
# tuned/full_test.sh <variant> — run llama.cpp's ctest suite against the build tuned/build.sh made
# for ONE variant and ONE CUDA toolkit, and write a results log next to the build tree.
#
#   CUDA_TAG=cu133 bash tuned/full_test.sh gb10
#
# The log is tuned/build/<cuda-tag>/releases/TEST_RESULTS_<variant>.log and ends with a
# "Full test suite summary" line. tuned/release.sh refuses to pass its gates unless that log shows a
# pass and is newer than the built libraries and binaries.
#
# The whole suite runs, including the tests labelled "model": they fetch small models from
# Hugging Face, so they need network access (and HF_TOKEN may be needed for rate limits).
export PATH="${CONDA_PREFIX:+$CONDA_PREFIX/bin:}$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Shells no longer export HF_TOKEN. When it is unset, load it from
# ~/.secrets/env/huggingface.env with dotfiles' parse-only helper (bashrc.d/lib/secrets.sh),
# so the model downloads are authenticated; without that file they run anonymously.
if [ -z "${HF_TOKEN:-}" ] && [ -r "$HOME/.secrets/env/huggingface.env" ] \
    && [ -r "${DOTFILES_DIR:-}/bashrc.d/lib/secrets.sh" ]; then
    # shellcheck source=/dev/null
    source "${DOTFILES_DIR}/bashrc.d/lib/secrets.sh" && secret_use huggingface
fi

GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/full_test.sh <variant>}"
REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPODIR}" || exit 1

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

BUILD_DIR="${LLAMA_TUNED_BUILD_DIR}"
RESULTS_FILE="${LLAMA_TUNED_TEST_LOG}"
mkdir -p "${LLAMA_TUNED_RELEASES_DIR}"
[ -f "${BUILD_DIR}/CTestTestfile.cmake" ] && [ -x "${BUILD_DIR}/bin/llama-server" ] \
    || { echo "ERROR: no finished build in ${BUILD_DIR}. Run tuned/build.sh ${GPU_TUNED_ARG_VARIANT} for ${CUDA_TAG} first." >&2; exit 1; }

# The toolkit's own lib dir first, so the host's ld.so.conf (which follows the /usr/local/cuda
# symlink) cannot satisfy cudart/cublas from another toolkit.
export LD_LIBRARY_PATH="${GPU_TUNED_TOOLKIT_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
gpu_tuned_verify_toolkit_libs "${BUILD_DIR}/bin/llama-server" || { echo "ERROR: llama-server does not resolve the ${CUDA_TAG} runtime libraries." >&2; exit 1; }

# The ctest "python" tests import llama.cpp's converter (torch, numpy, ...), which the host python3 does not have. Give
# them a per-toolkit venv with tuned/test-requirements.txt and this checkout's gguf-py (editable), and put it first on
# PATH so ctest's python3 is the venv's.
TEST_VENV="${LLAMA_TUNED_BUILD_ROOT}/test-venv"
gpu_tuned_setup_build_venv "${TEST_VENV}" "${REPODIR}" || { echo "ERROR: could not set up the test venv ${TEST_VENV}." >&2; exit 1; }
gpu_tuned_pip_install_requirements "${REPODIR}/tuned/test-requirements.txt" --quiet --disable-pip-version-check \
    || { echo "ERROR: could not install tuned/test-requirements.txt into ${TEST_VENV}." >&2; exit 1; }
python3 -m pip install --quiet --disable-pip-version-check --no-deps -e "${REPODIR}/gguf-py" \
    || { echo "ERROR: could not install gguf-py into ${TEST_VENV}." >&2; exit 1; }
gpu_tuned_check_venv_resolution || exit 1

{
    echo "llama.cpp full test suite -- variant=${GPU_TUNED_VARIANT} cuda=${CUDA_VER} (${CUDA_TAG})"
    echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "commit:  ${LLAMA_TUNED_BUILD_COMMIT}"
    echo "release: $(cat "${BUILD_DIR}/release-label" 2>/dev/null || echo unknown)"
    echo "build:   ${BUILD_DIR}"
    echo "gates: toolkit libs resolve under ${CUDA_HOME}"
    echo "tests:   ctest, all labels (main, model, python)"
    echo "python:  $(python3 --version 2>&1) in ${TEST_VENV}; torch $(python3 -c 'import torch; print(torch.__version__)' 2>/dev/null || echo missing)"
    echo ""
} > "${RESULTS_FILE}"

# pipefail: the exit status below must be ctest's, not tee's.
set -o pipefail
(cd "${BUILD_DIR}" && ctest --output-on-failure --no-tests=error -C Release 2>&1) | tee -a "${RESULTS_FILE}"
STATUS=$?

echo "" >> "${RESULTS_FILE}"
if [ "${STATUS}" -eq 0 ]; then
    echo "=== Full test suite summary: ctest passed ===" | tee -a "${RESULTS_FILE}"
else
    echo "=== Full test suite summary: ctest FAILED (exit ${STATUS}) ===" | tee -a "${RESULTS_FILE}"
fi
echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${RESULTS_FILE}"
echo "Results written to ${RESULTS_FILE}"
exit "${STATUS}"

#!/bin/bash
# tuned/env.sh <variant> — single source of truth for a tuned llama.cpp
# build's CUDA toolkit selection and device metadata. Source this file
# with the variant as $1; do not execute it directly.
#
# Follows the same GPU_TUNED_* convention as zbrad/raft, zbrad/cuvs, and
# zbrad/faiss's tuned/env.sh (same variable names, same
# gpu_tuned_verify_arch/embed_build_info function signatures) so a reader
# already familiar with those doesn't have to relearn a different
# convention here. llama.cpp itself has no VERSION file (unlike the RAPIDS
# repos) -- its own build system already derives BUILD_NUMBER as
# `git rev-list --count HEAD` (see cmake/build-info.cmake) and BUILD_COMMIT
# as `git rev-parse --short HEAD`; this file derives those the same way so
# a release tag always matches what `llama-cli --version` itself reports.
#
#   CUDA_TAG=cu133 bash tuned/package.sh gb10     (or CUDA_VER=13.3)
#
# The toolkit comes from the vendored definitions in tuned/common-data/
# toolkits/<id>.env (zbrad/tuned-common), never from /usr/local/cuda or from
# whatever happens to be installed. With neither CUDA_TAG nor CUDA_VER set, the
# highest defined toolkit is used and the available list and the reason are
# printed. Repo-specific settings live in tuned/repo.env, loaded last; it may
# not change any shared key (a conflict is a loud error).

GPU_TUNED_ARG_VARIANT="$1"
if [[ -z "${GPU_TUNED_ARG_VARIANT}" ]]; then
    echo "ERROR: env.sh requires a variant argument (gb10; rtx40/rtx50 not yet added)" >&2
    return 1 2>/dev/null || exit 1
fi

GPU_TUNED_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_TUNED_DATA_DIR="${GPU_TUNED_SELF_DIR}/common-data"
# shellcheck source=common-data/devices/gb10.conf
source "${GPU_TUNED_DATA_DIR}/devices/${GPU_TUNED_ARG_VARIANT}.conf" || return 1 2>/dev/null || exit 1
export GPU_TUNED_VARIANT GPU_TUNED_PLATFORM GPU_TUNED_CUDA_ARCH GPU_TUNED_HW_LABEL

# shellcheck source=common.sh
# Vendored from https://github.com/zbrad/tuned-common (pinned commit --
# see common.sh's own header/sync instructions to update). Provides
# gpu_tuned_installed_cuda_toolkits/verify_arch/verify_cuda_compat/
# embed_build_info/assert_platform, shared verbatim across the whole
# tuned-builds fleet instead of being hand-copied-and-edited per repo.
source "${GPU_TUNED_SELF_DIR}/common.sh" || return 1 2>/dev/null || exit 1

gpu_tuned_assert_platform "${GPU_TUNED_PLATFORM}" "${GPU_TUNED_VARIANT}" || return 1 2>/dev/null || exit 1

# --- Build identity: same derivation as cmake/build-info.cmake, so a
#     release tag always matches `llama-cli --version`'s own output. ---
REPODIR="$(cd "${GPU_TUNED_SELF_DIR}/.." && pwd)"
# Respect pre-set overrides (e.g. when re-packaging an already-built binary
# after a tooling-only commit that didn't require a rebuild -- the git-HEAD
# derivation below would otherwise mismatch what `llama-cli --version`
# actually reports for that binary).
: "${LLAMA_TUNED_BUILD_NUMBER:=$(git -C "${REPODIR}" rev-list --count HEAD 2>/dev/null || echo 0)}"
: "${LLAMA_TUNED_BUILD_COMMIT:=$(git -C "${REPODIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
export LLAMA_TUNED_BUILD_NUMBER LLAMA_TUNED_BUILD_COMMIT

# --- CUDA toolkit: chosen from tuned/common-data/toolkits, never inferred from
#     /usr/local/cuda or from what is installed. CUDA_TAG (cu133) or CUDA_VER
#     (13.3) select one; neither set means the highest defined, stated loudly. ---
_llama_tk="${CUDA_TAG:-}"
_llama_req_ver="${CUDA_VER:-}"
if [ -z "${_llama_tk}" ] && [ -n "${_llama_req_ver}" ]; then
    _llama_tk="cu${_llama_req_ver//./}"                         # 13.3 -> cu133
fi
gpu_tuned_load_toolkit "${GPU_TUNED_DATA_DIR}" "${GPU_TUNED_VARIANT}" "${_llama_tk}" || return 1 2>/dev/null || exit 1
if [ -n "${_llama_req_ver}" ] && [ "${_llama_req_ver}" != "${TOOLKIT_CUDA_VER}" ]; then
    echo "[tuned/env] ERROR: CUDA_VER=${_llama_req_ver} conflicts with toolkit ${CUDA_TAG} (CUDA ${TOOLKIT_CUDA_VER})." >&2
    return 1 2>/dev/null || exit 1
fi
unset _llama_tk _llama_req_ver
gpu_tuned_verify_toolkit || return 1 2>/dev/null || exit 1

# --- Repo-specific settings (CMake flags, ...), loaded last; may not change
#     any shared device/toolkit key. ---
gpu_tuned_load_repo_env "${GPU_TUNED_SELF_DIR}/repo.env" || return 1 2>/dev/null || exit 1

# --- Output layout: one build tree per toolkit and variant, build-tuned/<cuda-tag>/<variant>/
#     (matched by the repo's /build* ignore, and apart from build/, which the local units run),
#     so two toolkits never share a CMake cache. The test log sits next to it; the release gate
#     reads it. LLAMA_TUNED_BUILD_DIR overrides the tree (the cache check in build.sh still
#     applies). ccache is per toolkit too. ---
LLAMA_TUNED_BUILD_ROOT="${REPODIR}/build-tuned"
: "${LLAMA_TUNED_BUILD_DIR:=$(gpu_tuned_cuda_subdir "${LLAMA_TUNED_BUILD_ROOT}" "${CUDA_TAG}" "${GPU_TUNED_VARIANT}")}" || return 1 2>/dev/null || exit 1
LLAMA_TUNED_TEST_LOG="${LLAMA_TUNED_BUILD_DIR}/TEST_RESULTS_${GPU_TUNED_VARIANT}.log"
export LLAMA_TUNED_BUILD_DIR LLAMA_TUNED_TEST_LOG
export CCACHE_DIR="${LLAMA_TUNED_BUILD_ROOT}/${CUDA_TAG}/ccache"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"

# gpu_tuned_verify_arch/gpu_tuned_verify_cuda_compat now come from
# common.sh (sourced above); call sites in package.sh pass
# GPU_TUNED_CUDA_ARCH explicitly (the shared version takes it as an arg
# instead of reading a global, since different repos in the fleet name
# their arch var differently).

# embed_build_info <binary-or-so-path> — thin wrapper over
# gpu_tuned_embed_build_info (common.sh) that keeps this repo's existing
# section name (.llama_tuned_build_info -- unchanged, so `readelf -p
# .llama_tuned_build_info <file>` still works exactly as documented) and
# folds llama.cpp's own build-identity fields (no VERSION file, unlike the
# RAPIDS repos -- BUILD_NUMBER/BUILD_COMMIT/CUDA_TAG derived above) into
# the "version" field instead of a plain semver.
embed_build_info() {
    local target="$1"
    gpu_tuned_embed_build_info "${target}" "${GPU_TUNED_VARIANT}" "llama_tuned" \
        "${LLAMA_TUNED_BUILD_NUMBER} (${LLAMA_TUNED_BUILD_COMMIT}), ${CUDA_TAG}" \
        "${GPU_TUNED_HW_LABEL}" "https://github.com/zbrad/llama.cpp"
}

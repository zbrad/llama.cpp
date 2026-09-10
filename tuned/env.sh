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
#   CUDA_VER=13.3  bash tuned/package.sh gb10
#   CUDA_TAG=cu133 bash tuned/package.sh gb10
#
# Defaults to the highest installed toolkit under /usr/local/cuda-<ver>.

GPU_TUNED_ARG_VARIANT="$1"
if [[ -z "${GPU_TUNED_ARG_VARIANT}" ]]; then
    echo "ERROR: env.sh requires a variant argument (gb10; rtx40/rtx50 not yet added)" >&2
    return 1 2>/dev/null || exit 1
fi

GPU_TUNED_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=devices/gb10.conf
source "${GPU_TUNED_SELF_DIR}/devices/${GPU_TUNED_ARG_VARIANT}.conf" || return 1 2>/dev/null || exit 1
export GPU_TUNED_VARIANT GPU_TUNED_PLATFORM GPU_TUNED_CUDA_ARCH GPU_TUNED_HW_LABEL GPU_TUNED_DEVICE_LABEL

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

# --- Resolve CUDA_VER / CUDA_TAG (specify either, derive the other) ---
if [ -n "${CUDA_VER:-}" ]; then
    : "${CUDA_TAG:=cu${CUDA_VER//./}}"                          # 13.3 -> cu133
elif [ -n "${CUDA_TAG:-}" ]; then
    _cuda_digits="${CUDA_TAG#cu}"                               # cu133 -> 133
    : "${CUDA_VER:=${_cuda_digits%?}.${_cuda_digits: -1}}"     # 133 -> 13.3
    unset _cuda_digits
fi
if [ -z "${CUDA_VER:-}" ]; then
    _llama_latest="$(gpu_tuned_installed_cuda_toolkits | tail -1)"
    CUDA_VER="${_llama_latest:-13.3}"  # last-resort fallback if nothing is installed yet
    unset _llama_latest
fi
export CUDA_VER
export CUDA_TAG="${CUDA_TAG:-cu${CUDA_VER//./}}"

# --- Resolve CUDA_HOME to the matching toolkit when not explicitly set ---
if [ -z "${CUDA_HOME:-}" ]; then
    if [ -d "/usr/local/cuda-${CUDA_VER}" ]; then
        export CUDA_HOME="/usr/local/cuda-${CUDA_VER}"
    else
        echo "[tuned/env] WARNING: /usr/local/cuda-${CUDA_VER} not found; falling back to /usr/local/cuda." >&2
        export CUDA_HOME="/usr/local/cuda"
    fi
fi
export PATH="$CUDA_HOME/bin:$PATH"

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

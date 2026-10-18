#!/bin/bash
# tuned/build.sh <variant> — configure and build llama.cpp for ONE variant and ONE CUDA toolkit
# into tuned/build/<cuda-tag>/cmake/ (never the shared build/ the local units run).
#
#   CUDA_TAG=cu133 bash tuned/build.sh gb10      # or CUDA_VER=13.3; one of them is required
#
# Then: bash tuned/full_test.sh gb10 && bash tuned/package.sh gb10 (or tuned/release.sh).
#
# The CMake flags come from tuned/repo.env, the compiler and arch from the toolkit and device
# files. The web UI must already be in tools/ui/dist (the llama-ui-tuned build): without it
# upstream's CMake would run `npm ci` on upstream's lockfile or download a UI.
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/build.sh <variant>}"

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

BUILD_DIR="${LLAMA_TUNED_BUILD_DIR}"

[[ -f "${REPODIR}/tools/ui/dist/index.html" ]] || {
    echo "ERROR: ${REPODIR}/tools/ui/dist/index.html not found. Extract the ui/ tree of a llama-ui-tuned tarball there first" >&2
    echo "       (see tuned/check-ui.sh); a build without it would fetch or npm-build an unaudited UI." >&2
    exit 1
}

# An existing CMake cache keeps the toolkit and source tree it was configured with, silently.
cache="${BUILD_DIR}/CMakeCache.txt"
if [[ -f "${cache}" ]]; then
    cached="$(sed -n 's/^CMAKE_CUDA_COMPILER:[A-Z]*=//p' "${cache}" | head -1)"
    if [[ -n "${cached}" && "${cached}" != "${CUDA_HOME}/bin/nvcc" ]]; then
        echo "ERROR: ${cache} was configured with ${cached}, but CUDA_HOME=${CUDA_HOME}. Remove ${BUILD_DIR} first." >&2
        exit 1
    fi
    cached="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "${cache}" | head -1)"
    if [[ -n "${cached}" && "${cached}" != "${REPODIR}" ]]; then
        echo "ERROR: ${cache} was configured for ${cached}, not ${REPODIR} (copied from another checkout?). Remove ${BUILD_DIR} first." >&2
        exit 1
    fi
fi

# The release label is allocated here, at the first stage that bakes it into the binary (it is compiled into
# build-info.cpp, so `llama-server --version` prints it), and recorded beside the build. package.sh and
# release.sh read it and never recompute it. It is the UTC date of HEAD's commit plus the lowest sequence not
# yet taken by a published tag; nothing reserves it until publish, so two builds on one date can carry the same
# label (the stamp's full commit tells them apart). GPU_TUNED_LABEL_SEQ=<n> chooses the sequence offline.
LABEL="$(gpu_tuned_allocate_date_label "${REPODIR}")" || exit 1
RELEASE_TAG="$(gpu_tuned_native_tag "${GPU_TUNED_VARIANT}" "${CUDA_TAG}" "${LABEL}")" || exit 1
mkdir -p "${BUILD_DIR}"
printf '%s\n' "${RELEASE_TAG}" > "${BUILD_DIR}/release-label"

# NCCL from a pinned zbrad/nccl release (tuned/nccl.pins): hand ggml's FindNCCL the static library and headers
# directly (it only searches for libnccl.so), and keep NCCL's symbols out of libggml-cuda's dynamic table so a
# second NCCL in the same process (pytorch's) cannot interpose on this one.
NCCL_ARGS=()
if [[ -n "${LLAMA_TUNED_NCCL_DIR}" ]]; then
    NCCL_ARGS=("-DNCCL_LIBRARY=${LLAMA_TUNED_NCCL_DIR}/lib/libnccl_static.a" "-DNCCL_INCLUDE_DIR=${LLAMA_TUNED_NCCL_DIR}/include"
               "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--exclude-libs,libnccl_static.a")
fi

LAUNCHER=()
if command -v ccache >/dev/null; then
    mkdir -p "${CCACHE_DIR}"
    LAUNCHER=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache)
fi

echo "Building llama.cpp ${RELEASE_TAG} (commit ${LLAMA_TUNED_BUILD_COMMIT}): ${CUDA_TAG} (CUDA ${CUDA_VER}), sm_${GPU_TUNED_CUDA_ARCH}"
echo "  Build dir : ${BUILD_DIR}"
# CMake takes the bare arch (121) and upgrades it to 121a itself.
cmake -S "${REPODIR}" -B "${BUILD_DIR}" "${LLAMA_TUNED_CMAKE_FLAGS[@]}" "${LAUNCHER[@]}" \
    "-DLLAMA_TUNED_RELEASE=${RELEASE_TAG}" "${NCCL_ARGS[@]}" \
    -DCMAKE_CUDA_COMPILER="${CUDA_HOME}/bin/nvcc" \
    -DCMAKE_CUDA_ARCHITECTURES="${GPU_TUNED_CUDA_ARCH//[a-z]/}"
cmake --build "${BUILD_DIR}" --config Release -j"$(gpu_tuned_jobs)"
echo "Built: ${BUILD_DIR}/bin"

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

if [[ "$(uname -m)" != "${GPU_TUNED_PLATFORM}" ]]; then
    echo "ERROR: tuned/env.sh: expected platform '${GPU_TUNED_PLATFORM}' for" \
         "variant '${GPU_TUNED_VARIANT}', but uname -m reports '$(uname -m)'." >&2
    return 1 2>/dev/null || exit 1
fi

# --- Build identity: same derivation as cmake/build-info.cmake, so a
#     release tag always matches `llama-cli --version`'s own output. ---
REPODIR="$(cd "${GPU_TUNED_SELF_DIR}/.." && pwd)"
LLAMA_TUNED_BUILD_NUMBER="$(git -C "${REPODIR}" rev-list --count HEAD 2>/dev/null || echo 0)"
LLAMA_TUNED_BUILD_COMMIT="$(git -C "${REPODIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
export LLAMA_TUNED_BUILD_NUMBER LLAMA_TUNED_BUILD_COMMIT

# --- List installed toolkits under /usr/local/cuda-<ver> (glob, sorted). ---
llama_tuned_installed_cuda_toolkits() {
    local d
    for d in /usr/local/cuda-[0-9]*; do
        [ -d "$d" ] && basename "$d" | sed 's/^cuda-//'
    done | sort -V
}

# --- Resolve CUDA_VER / CUDA_TAG (specify either, derive the other) ---
if [ -n "${CUDA_VER:-}" ]; then
    : "${CUDA_TAG:=cu${CUDA_VER//./}}"                          # 13.3 -> cu133
elif [ -n "${CUDA_TAG:-}" ]; then
    _cuda_digits="${CUDA_TAG#cu}"                               # cu133 -> 133
    : "${CUDA_VER:=${_cuda_digits%?}.${_cuda_digits: -1}}"     # 133 -> 13.3
    unset _cuda_digits
fi
if [ -z "${CUDA_VER:-}" ]; then
    _llama_latest="$(llama_tuned_installed_cuda_toolkits | tail -1)"
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

# gpu_tuned_verify_arch <path-to-.so-or-binary> — confirms the file's
# embedded cubin(s) are EXACTLY sm_${GPU_TUNED_CUDA_ARCH}, via cuobjdump.
# Same name/signature as zbrad/raft/cuvs/faiss's tuned/env.sh equivalent.
gpu_tuned_verify_arch() {
    local so_file="$1"
    if [[ ! -f "${so_file}" ]]; then
        echo "ERROR: gpu_tuned_verify_arch: no such file: ${so_file}" >&2
        return 1
    fi
    command -v cuobjdump >/dev/null 2>&1 || {
        echo "ERROR: gpu_tuned_verify_arch: cuobjdump not found on PATH (expected under \$CUDA_HOME/bin)." >&2
        return 1
    }
    local found found_count
    found="$(cuobjdump --list-elf "${so_file}" 2>/dev/null | grep -oE 'sm_[0-9]+[a-z]?' | sort -u)"
    if [[ -z "${found}" ]]; then
        echo "ERROR: gpu_tuned_verify_arch: cuobjdump found no embedded cubins in ${so_file} at all." >&2
        return 1
    fi
    found_count="$(echo "${found}" | wc -l)"
    if [[ "${found_count}" -ne 1 ]]; then
        echo "ERROR: ${so_file} embeds MULTIPLE arch targets ($(echo "${found}" | tr '\n' ' ')) -- expected a single-arch tuned build." >&2
        return 1
    fi
    if [[ "${found}" != "sm_${GPU_TUNED_CUDA_ARCH}" ]]; then
        echo "ERROR: ${so_file} is not built for sm_${GPU_TUNED_CUDA_ARCH} (found: ${found})." >&2
        return 1
    fi
    echo "OK: ${so_file} confirmed single-arch ${found} (matches requested sm_${GPU_TUNED_CUDA_ARCH})"
}

# gpu_tuned_verify_cuda_compat <path-to-.so> <expected-cuda-ver> — confirms
# NEEDED libcudart.so.<major> matches the CUDA major version this build
# expects (CUDA runtime ABI is forward-compatible only within a major
# series). Same name/signature as the other repos' tuned/env.sh equivalent.
gpu_tuned_verify_cuda_compat() {
    local so_file="$1" expected_cuda_ver="$2"
    if [[ ! -f "${so_file}" ]]; then
        echo "ERROR: gpu_tuned_verify_cuda_compat: no such file: ${so_file}" >&2
        return 1
    fi
    command -v objdump >/dev/null 2>&1 || {
        echo "ERROR: gpu_tuned_verify_cuda_compat: objdump not found on PATH." >&2
        return 1
    }
    local needed found_major expected_major
    needed="$(objdump -p "${so_file}" 2>/dev/null | grep -oE 'libcudart\.so\.[0-9]+' | head -1)"
    if [[ -z "${needed}" ]]; then
        echo "WARNING: ${so_file} has no direct libcudart.so.N NEEDED entry -- skipping CUDA runtime compat check." >&2
        return 0
    fi
    found_major="${needed##*.}"
    expected_major="${expected_cuda_ver%%.*}"
    if [[ "${found_major}" != "${expected_major}" ]]; then
        echo "ERROR: ${so_file} was linked against CUDA runtime major ${found_major}" \
             "(${needed}), but this build expects CUDA ${expected_cuda_ver}" \
             "(major ${expected_major})." >&2
        return 1
    fi
    echo "OK: ${so_file} CUDA runtime compat confirmed (${needed}, matches expected major ${expected_major})"
}

# embed_build_info <binary-or-so-path> — embeds a greppable build-info
# string into a custom ELF section (.llama_tuned_build_info), readable via
# `readelf -p .llama_tuned_build_info <file>` or plain `strings`. Safe at
# runtime: a custom section with no program-header entry is ignored by the
# dynamic loader/exec. Same technique as zbrad/raft/cuvs's embed_build_info
# (.raft_build_info / .cuvs_build_info).
#
# Defensively removes any prior stamp before adding -- objcopy --add-section
# on a section name that already exists (e.g. re-packaging the same build
# tree a second time without a clean rebuild) has been observed elsewhere
# in this chain (cuvs's own comment) to corrupt the in-place rewrite.
embed_build_info() {
    local target="$1"
    local tmp
    tmp="$(mktemp)"
    echo "llama.cpp-${GPU_TUNED_VARIANT} build: ${LLAMA_TUNED_BUILD_NUMBER} (${LLAMA_TUNED_BUILD_COMMIT}), ${CUDA_TAG}, ${GPU_TUNED_HW_LABEL}, https://github.com/zbrad/llama.cpp, built $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${tmp}"
    objcopy --remove-section .llama_tuned_build_info "${target}" 2>/dev/null || true
    objcopy --add-section .llama_tuned_build_info="${tmp}" "${target}"
    rm -f "${tmp}"
}

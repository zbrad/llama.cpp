#!/bin/bash
# tuned/package.sh <variant> — package an already-built (per
# docs/spark/README.md's `cmake -B build ...` command) build/bin/ output
# into a tarball and publish it as a real GitHub release, so downstream
# consumers (zbrad/ollama's fetch script) can pull a published build
# instead of reaching into a local sibling checkout.
#
# Usage:
#   cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121   # first
#   cmake --build build --config Release -j$(nproc)                # first
#   bash tuned/package.sh gb10                                      # then
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/package.sh <variant>}"

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

BUILD_DIR="${LLAMA_TUNED_BUILD_DIR:-${REPODIR}/build}"
BIN_DIR="${BUILD_DIR}/bin"

echo "===================================================="
echo "llama.cpp ${GPU_TUNED_HW_LABEL} Package"
echo "===================================================="
echo ""
echo "  Build dir : ${BIN_DIR}"
echo "  Build     : ${LLAMA_TUNED_BUILD_NUMBER} (${LLAMA_TUNED_BUILD_COMMIT})"
echo "  CUDA      : ${CUDA_TAG}"
echo ""

# The exact set of files zbrad/ollama's deploy/fetch script consumes --
# keep in sync with that script's copy list.
BINARIES=(llama-server llama-quantize)
for b in "${BINARIES[@]}"; do
    if [[ ! -f "${BIN_DIR}/${b}" ]]; then
        echo "ERROR: ${BIN_DIR}/${b} not found. Build first (see usage above)." >&2
        exit 1
    fi
done

# Real .so files (both versioned like libggml-base.so.0.19.0 AND bare
# like libllama-server-impl.so -- llama-server/llama-quantize each link a
# same-named unversioned *-impl.so that a narrower "*.so.*"-only glob
# misses entirely: confirmed via `ldd build/bin/llama-server`, which was
# the actual root cause of a real "cannot open shared object file: No
# such file or directory" failure on a deployed release before this fix).
# Excludes dev symlinks -- those get recreated by soname normalization on
# the consuming side, same as the ollama deploy script already does.
mapfile -t SO_FILES < <(find "${BIN_DIR}" -maxdepth 1 \( -name '*.so.*' -o -name '*.so' \) -not -type l | sort)
if [[ "${#SO_FILES[@]}" -eq 0 ]]; then
    echo "ERROR: no lib*.so* files found under ${BIN_DIR}." >&2
    exit 1
fi

CUDA_SO="${BIN_DIR}/$(basename "$(find "${BIN_DIR}" -maxdepth 1 -name 'libggml-cuda.so.*' -not -type l | head -1)")"
gpu_tuned_verify_arch "${CUDA_SO}"
gpu_tuned_verify_cuda_compat "${CUDA_SO}" "${CUDA_VER}"

# Stamp build-info onto the two primary consumer-facing artifacts: the
# server binary itself, and the GPU-specific .so (mirrors the other repos'
# convention of stamping the arch-specific artifact, plus the binary users
# actually invoke).
embed_build_info "${BIN_DIR}/llama-server"
embed_build_info "${CUDA_SO}"

DIST_DIR="${REPODIR}/dist/${GPU_TUNED_VARIANT}"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
TARBALL="${DIST_DIR}/llama-cpp-${LLAMA_TUNED_BUILD_NUMBER}-${GPU_TUNED_VARIANT}-${CUDA_TAG}.tar.gz"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
for b in "${BINARIES[@]}"; do
    cp -p "${BIN_DIR}/${b}" "${STAGE}/"
done
for so in "${SO_FILES[@]}"; do
    cp -p "${so}" "${STAGE}/"
    # Also stage the bare SONAME (e.g. libggml-base.so.0): the dynamic
    # loader resolves DT_NEEDED entries by this exact filename, not by the
    # fully-versioned one -- confirmed via `readelf -d`/`ldd` empirically
    # (a deploy without this symlink silently fell back to this build
    # machine's own build/bin/ via the RUNPATH stripped below, meaning it
    # only ever "worked" by accident on the machine it was built on).
    so_name="$(basename "${so}")"
    soname="$(readelf -d "${so}" 2>/dev/null | grep -oP '(?<=Library soname: \[)[^\]]+')"
    if [[ -n "${soname}" && "${soname}" != "${so_name}" ]]; then
        cp -p "${so}" "${STAGE}/${soname}"
    fi
done

# Detect and stage system-library dependencies that CMake itself never
# produces (so the SO_FILES glob above can't find them) but that every
# staged binary/lib links against anyway. Concrete case that motivated
# this: libnccl.so.2 -- confirmed via a real deploy to a second machine
# failing with "error while loading shared libraries: libnccl.so.2: cannot
# open shared object file", even though that machine had a matching
# driver/CUDA-toolkit setup. `ldd` showed every staged file links it, but
# it's just the build machine's apt package (libnccl2), never copied into
# BIN_DIR by CMake.
#
# Allowlist below is everything assumed already present on any target that
# passed precheck-tuned.sh, so it's deliberately NOT bundled:
#   - base glibc/gcc runtime (libc, libm, libdl, libpthread, librt,
#     libgcc_s, libstdc++, libgomp, ld-linux, linux-vdso)
#   - libcuda.so.* -- the NVIDIA *driver's* userspace lib. Must NEVER be
#     bundled: it has to be the exact one matching the target's own
#     installed driver, not the build machine's, or you'd potentially ship
#     a mismatched driver ABI.
#   - libcudart/libcublas/libcublasLt -- CUDA *toolkit* runtime libs,
#     already required by precheck-tuned.sh's CUDA-toolkit-presence check.
# Anything else resolved to a real system path -- like libnccl -- gets
# staged automatically, so this doesn't need a new hardcoded name every
# time the build happens to pick up a fresh stray dependency.
ASSUME_PRESENT_RE='^(linux-vdso\.so|ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libgcc_s\.so|libstdc\+\+\.so|libgomp\.so|libcuda\.so|libcudart\.so|libcublas\.so|libcublasLt\.so)'

declare -A EXTRA_SYSTEM_LIBS=()
for f in "${BIN_DIR}/llama-server" "${BIN_DIR}/llama-quantize" "${SO_FILES[@]}"; do
    while IFS= read -r deppath; do
        [[ -n "${deppath}" ]] || continue
        dep_name="$(basename "${deppath}")"
        [[ "${dep_name}" =~ ${ASSUME_PRESENT_RE} ]] && continue
        [[ "${deppath}" == "${BIN_DIR}"/* ]] && continue   # our own staged libs
        EXTRA_SYSTEM_LIBS["${deppath}"]=1
    done < <(ldd "${f}" 2>/dev/null | awk '
        /=>/  { if ($3 ~ /^\//) print $3; next }
        /^[[:space:]]*\// { print $1 }
    ')
done

if [[ "${#EXTRA_SYSTEM_LIBS[@]}" -gt 0 ]]; then
    echo ""
    echo "Staging extra system library dependencies (not produced by this"
    echo "build, not assumed already present on the target):"
fi
for deppath in "${!EXTRA_SYSTEM_LIBS[@]}"; do
    real="$(readlink -f "${deppath}")"
    if [[ ! -f "${real}" ]]; then
        echo "ERROR: dependency ${deppath} not found on this machine." >&2
        exit 1
    fi
    echo "  ${real}"
    real_name="$(basename "${real}")"
    cp -p "${real}" "${STAGE}/${real_name}"
    soname="$(readelf -d "${real}" 2>/dev/null | grep -oP '(?<=Library soname: \[)[^\]]+')"
    if [[ -n "${soname}" && "${soname}" != "${real_name}" && ! -e "${STAGE}/${soname}" ]]; then
        cp -p "${real}" "${STAGE}/${soname}"
    fi
    SO_FILES+=("${real}")
done

# Patch RUNPATH on every staged binary/lib to $ORIGIN, replacing the
# absolute build-machine path CMake bakes in by default (confirmed via
# `readelf -d`: RUNPATH was literally "/home/zbrad/gh/llama.cpp/build/bin"
# -- fine for running in-place on the machine that built it, but silently
# broken -- falls back to whatever happens to exist at that exact absolute
# path, or nothing at all -- once deployed anywhere else, including this
# same machine's Ollama install). $ORIGIN makes each file resolve its
# sibling libs relative to wherever it's actually deployed.
for f in "${STAGE}"/*; do
    [[ -f "${f}" && ! -L "${f}" ]] || continue
    if readelf -d "${f}" 2>/dev/null | grep -qE 'RPATH|RUNPATH'; then
        patchelf --set-rpath '$ORIGIN' "${f}"
    fi
done

echo ""
echo "Packaging $(basename "${STAGE}")'s $(ls "${STAGE}" | wc -l) files -> ${TARBALL}..."
tar -C "${STAGE}" -czf "${TARBALL}" .
echo "Tarball: $(basename "${TARBALL}") ($(du -sh "${TARBALL}" | awk '{print $1}'))"

RELEASE_TAG="v${LLAMA_TUNED_BUILD_NUMBER}-${GPU_TUNED_VARIANT}-${CUDA_TAG}"
RELEASE_TITLE="llama.cpp ${LLAMA_TUNED_BUILD_NUMBER} (${LLAMA_TUNED_BUILD_COMMIT}) — ${GPU_TUNED_HW_LABEL} (${CUDA_TAG})"

echo ""
echo "Publishing to GitHub release ${RELEASE_TAG}..."
gh release create "${RELEASE_TAG}" \
    --repo zbrad/llama.cpp \
    --title "${RELEASE_TITLE}" \
    --target "tuned-builds" \
    --notes "llama-server + llama-quantize + $(( ${#SO_FILES[@]} )) shared libraries, single-arch (sm_${GPU_TUNED_CUDA_ARCH}), built against CUDA ${CUDA_VER}. Includes the Ollama-format GGUF compatibility shim. Deploy into an Ollama installation via zbrad/ollama's tuned-builds fetch script, or manually: extract and copy llama-server + libs to your Ollama lib directory, symlinking llama-server into place (see zbrad/ollama's docs/local-llama-cpp.md)." \
    "${TARBALL}#$(basename "${TARBALL}")"

echo ""
echo "Done: https://github.com/zbrad/llama.cpp/releases/tag/${RELEASE_TAG}"

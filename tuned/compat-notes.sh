#!/bin/bash
# tuned/compat-notes.sh <variant> <lib-dir> — print the "CUDA / driver
# compatibility" section (markdown) of a tuned release's notes, derived
# from the packaged libraries in <lib-dir> plus this build's env.sh
# variables (CUDA_VER, GPU_TUNED_CUDA_ARCH). package.sh runs it on its
# staging dir; it can also be run on an extracted release tarball to
# regenerate an already-published release's section:
#
#   CUDA_VER=13.3 bash tuned/compat-notes.sh gb10 /path/to/extracted
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/compat-notes.sh <variant> <lib-dir>}"
LIB_DIR="${2:?usage: tuned/compat-notes.sh <variant> <lib-dir>}"

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" >/dev/null || exit 1

COMPAT_URL="https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html"
CUDA_MAJOR="${CUDA_VER%%.*}"

# Minimum driver branch for CUDA minor version compatibility (any
# <major>.x application runs on a driver from this branch on), per the
# NVIDIA release notes above. Unknown majors fail rather than guess.
case "${CUDA_MAJOR}" in
    13) MIN_DRIVER=580 ;;
    *)  echo "ERROR: no minimum-driver entry for CUDA ${CUDA_MAJOR}.x in tuned/compat-notes.sh" >&2; exit 1 ;;
esac

# Features added after CUDA <major>.0 need a newer driver branch than the
# minimum above. ggml-cuda gates such code on CUDART_VERSION; any guard
# above <major>.0 means this build may use one, which needs a human to
# word the notes, so stop instead of printing "none".
base=$(( CUDA_MAJOR * 1000 ))
newer="$(grep -rhoE 'CUDART_VERSION *>=? *[0-9]{5}' "${REPODIR}/ggml/src/ggml-cuda" \
    | sed -E 's/CUDART_VERSION *//' \
    | awk -v base="${base}" '{ op = ($0 ~ /^>=/) ? ">=" : ">"; n = $0; gsub(/[^0-9]/, "", n);
                              if ((op == ">=" && n > base) || (op == ">" && n >= base)) print op n }' \
    | sort -u)"
if [[ -n "${newer}" ]]; then
    echo "ERROR: ggml-cuda has CUDART_VERSION guards above CUDA ${CUDA_MAJOR}.0 ($(echo "${newer}" | tr '\n' ' '))." >&2
    echo "       Work out which driver branch they need and update tuned/compat-notes.sh." >&2
    exit 1
fi

CUDA_SO="$(find "${LIB_DIR}" -maxdepth 1 -name 'libggml-cuda.so.*' -not -type l | head -1)"
[[ -n "${CUDA_SO}" ]] || { echo "ERROR: no libggml-cuda.so.* in ${LIB_DIR}" >&2; exit 1; }
cubins="$(cuobjdump --list-elf "${CUDA_SO}" 2>/dev/null | grep -oE 'sm_[0-9]+[a-z]?' || true)"
cubin_count="$(echo "${cubins}" | grep -c . || true)"
[[ "${cubin_count}" -gt 0 ]] || { echo "ERROR: no cubins found in ${CUDA_SO}" >&2; exit 1; }
ptx_note=""
ptx="$(cuobjdump --list-ptx "${CUDA_SO}" 2>/dev/null || true)"
if grep -q "sm_${GPU_TUNED_CUDA_ARCH}" <<<"${ptx}"; then
    ptx_note=" plus PTX"
fi

# CUDA toolkit libraries the packaged files need but that are not bundled
# (package.sh's ASSUME_PRESENT_RE), from their own NEEDED entries.
mapfile -t host_libs < <(
    for f in "${LIB_DIR}"/*; do
        [[ -f "${f}" && ! -L "${f}" ]] || continue
        readelf -d "${f}" 2>/dev/null | grep -oP '(?<=Shared library: \[)libcu(dart|blas|blasLt)\.so[^\]]*' || true
    done | sort -u | while read -r lib; do [[ -e "${LIB_DIR}/${lib}" ]] || echo "${lib}"; done
)
host_libs_text="none"
if [[ "${#host_libs[@]}" -gt 0 ]]; then
    host_libs_text="$(printf '`%s`, ' "${host_libs[@]}")"
    host_libs_text="${host_libs_text%, } from any CUDA ${CUDA_MAJOR}.x install"
fi
[[ "${GPU_TUNED_VARIANT}" == "gb10" ]] && host_libs_text+=" (DGX OS ships 13.0)"

tested="$(awk -v v="${GPU_TUNED_VARIANT}" '!/^#/ && $1 == v {
              printf "  - %s, tested with %s: ", $2, $3
              $1 = $2 = $3 = ""; sub(/^ +/, ""); print }' "${REPODIR}/tuned/tested-drivers.txt")"
[[ -n "${tested}" ]] || tested="  - none recorded yet"

cat <<EOF
### CUDA / driver compatibility

- **Built with:** CUDA ${CUDA_VER}.
- **Minimum driver:** R${MIN_DRIVER} (>= ${MIN_DRIVER}). CUDA ${CUDA_MAJOR}.x applications run on any driver from that branch on; see "CUDA minor version compatibility" in NVIDIA's [CUDA toolkit release notes](${COMPAT_URL}).
- Features introduced after CUDA ${CUDA_MAJOR}.0 need newer driver branches. Ones this build uses: none.
- **GPU code:** cubin for sm_${GPU_TUNED_CUDA_ARCH} (${cubin_count} modules)${ptx_note}. Runs only on that GPU; the driver loads the cubin directly, so nothing is JIT-compiled at load.
- **Host libraries required:** ${host_libs_text}. \`libcuda.so.1\` comes with the NVIDIA driver.
- **Tested on (driver):**
${tested}
EOF

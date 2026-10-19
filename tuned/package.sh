#!/bin/bash
# tuned/package.sh <variant> — package the build tuned/build.sh made (and tuned/full_test.sh
# tested) for ONE variant and ONE CUDA toolkit into tuned/build/<cuda-tag>/dist/llama-cpp-0.<date>.<seq>-<variant>-<cuda>.tar.gz
# with a .sha256 sidecar and package-info.txt, then check the tarball as a consumer gets it
# (extract, version, ldd, RUNPATH, toolkit libs). It packages only: no tag, no publishing.
# tuned/release.sh publishes exactly these files, with the tracked release notes
# (tuned/releases/RELEASE_NOTES_0.<date>.<seq>_<variant>_<cuda>.md; a draft is written here if there is none).
# Same split as raft, cuvs and faiss.
#
#   CUDA_TAG=cu133 bash tuned/build.sh gb10 && CUDA_TAG=cu133 bash tuned/full_test.sh gb10
#   CUDA_TAG=cu133 bash tuned/package.sh gb10
#   CUDA_TAG=cu133 bash tuned/smoke_test.sh gb10     # installs the package with install.sh and uses it
#   (review and commit the notes, remove the DRAFT banner)
#   CUDA_TAG=cu133 bash tuned/release.sh gb10 [--publish]
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/package.sh <variant>}"

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

BUILD_DIR="${LLAMA_TUNED_BUILD_DIR}"   # from env.sh: tuned/build/<cuda-tag>/cmake
BIN_DIR="${BUILD_DIR}/bin"

echo "===================================================="
echo "llama.cpp ${GPU_TUNED_HW_LABEL} Package"
echo "===================================================="
echo ""
echo "  Build dir : ${BIN_DIR}"
echo "  Commit    : ${LLAMA_TUNED_BUILD_COMMIT}"
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

# The binaries must come from HEAD, or from a commit that differs from HEAD only under tuned/ (packaging
# scripts, not source). Fails closed: a build commit git does not know cannot be checked.
if ! git -C "${REPODIR}" cat-file -e "${LLAMA_TUNED_BUILD_COMMIT}^{commit}" 2>/dev/null; then
    echo "ERROR: build commit ${LLAMA_TUNED_BUILD_COMMIT} is not known to git, so it cannot be checked against HEAD." >&2
    exit 1
fi
outside_tuned="$(git -C "${REPODIR}" diff --name-only "${LLAMA_TUNED_BUILD_COMMIT}" HEAD | grep -v '^tuned/' || true)"
if [[ -n "${outside_tuned}" ]]; then
    echo "ERROR: files outside tuned/ differ between build commit ${LLAMA_TUNED_BUILD_COMMIT} and HEAD; rebuild at HEAD." >&2
    echo "${outside_tuned}" | head -5 >&2
    exit 1
fi

# Incremental builds never delete old versioned libs when CMake bumps a
# SONAME (e.g. libggml-cuda.so.0.19.0 lingering after a rebuild produces
# .0.23.0) -- the glob below would otherwise stage every stale generation
# alongside the current one, bloating the tarball. Drop anything that
# isn't the active bare-symlink's target before staging.
for link in "${BIN_DIR}"/*.so; do
    [[ -L "${link}" ]] || continue
    base="$(basename "${link}" .so)"
    active="$(basename "$(readlink -f "${link}")")"
    for f in "${BIN_DIR}/${base}".so.*; do
        [[ -f "${f}" && ! -L "${f}" ]] || continue  # skip missing + intermediate SONAME symlinks (e.g. libfoo.so.0), only real versioned files are candidates
        [[ "$(basename "${f}")" == "${active}" ]] && continue
        echo "  removing stale build artifact: $(basename "${f}")"
        rm -f "${f}"
    done
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
gpu_tuned_verify_arch "${CUDA_SO}" "${GPU_TUNED_CUDA_ARCH}"
gpu_tuned_verify_cuda_compat "${CUDA_SO}" "${CUDA_VER}"

# (Build-info is stamped onto the STAGED copies below, never onto the build tree: stamping the
# build tree rewrites the very files the test log is compared against, and release.sh's
# "log newer than the build" gate would fail after every packaging run.)

# The web UI embedded in llama-server must be the audited llama-ui-tuned build, from the same
# tools/ui sources as this checkout; never upstream's lockfile built or downloaded by CMake.
UI_BUILD="$(bash "${REPODIR}/tuned/check-ui.sh" "${BUILD_DIR}")" || exit 1

# Release identity: the native tag v0.<date>.<seq>-<variant>-<cuda> that tuned/build.sh allocated and compiled into
# the binary (`llama-server --version` prints it), read from the build tree and checked: it must be a valid
# date-label tag for this variant and toolkit, and the packaged binary must print it. Not recomputed here.
[[ -f "${BUILD_DIR}/release-label" ]] || { echo "ERROR: ${BUILD_DIR}/release-label not found; run tuned/build.sh ${GPU_TUNED_VARIANT} for ${CUDA_TAG}." >&2; exit 1; }
RELEASE_TAG="$(head -1 "${BUILD_DIR}/release-label")"
gpu_tuned_check_release_tag "${RELEASE_TAG}" || exit 1
[[ "${RELEASE_TAG}" == v0.*-"${GPU_TUNED_VARIANT}-${CUDA_TAG}" ]] || { echo "ERROR: the build's release ${RELEASE_TAG} is not for ${GPU_TUNED_VARIANT}-${CUDA_TAG}." >&2; exit 1; }
echo "  Release   : ${RELEASE_TAG}"
DIST_DIR="${LLAMA_TUNED_DIST_DIR}"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
TARBALL="${DIST_DIR}/llama-cpp-${RELEASE_TAG#v}.tar.gz"

STAGE="$(mktemp -d)"
# Provenance manifests (outside STAGE, so they never ship): the shared objects THIS build
# produced, which get a unique identity below, and the bundled system libraries, which do not.
OURS_MANIFEST="$(mktemp)"
OURS_NAMES=()
SYSTEM_MANIFEST="$(mktemp)"
trap 'rm -rf "${STAGE}" "${OURS_MANIFEST}" "${SYSTEM_MANIFEST}"' EXIT
for b in "${BINARIES[@]}"; do
    cp -p "${BIN_DIR}/${b}" "${STAGE}/${b}-tuned"   # shipped name never collides with upstream's
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
    OURS_NAMES+=("${so_name}")
    soname="$(readelf -d "${so}" 2>/dev/null | grep -oP '(?<=Library soname: \[)[^\]]+')"
    if [[ -n "${soname}" && "${soname}" != "${so_name}" ]]; then
        cp -p "${so}" "${STAGE}/${soname}"
        OURS_NAMES+=("${soname}")
    fi
done

# Stamp the JSON build info onto the two primary consumer-facing artifacts: the server binary itself, and
# the GPU-specific .so (every staged copy of it, SONAME copy included). Staged copies only: stamping the build
# tree would make it newer than its test log.
embed_build_info "${STAGE}/llama-server-tuned" llama-server-tuned "${RELEASE_TAG}" "${UI_BUILD% *}" "${UI_BUILD#* }" || exit 1
for f in "${STAGE}"/libggml-cuda.so*; do
    [[ -f "${f}" && ! -L "${f}" ]] && { embed_build_info "${f}" ggml-cuda-tuned "${RELEASE_TAG}" "${UI_BUILD% *}" "${UI_BUILD#* }" || exit 1; }
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
    echo "${real_name}" >> "${SYSTEM_MANIFEST}"
    soname="$(readelf -d "${real}" 2>/dev/null | grep -oP '(?<=Library soname: \[)[^\]]+')"
    if [[ -n "${soname}" && "${soname}" != "${real_name}" && ! -e "${STAGE}/${soname}" ]]; then
        cp -p "${real}" "${STAGE}/${soname}"
        echo "${soname}" >> "${SYSTEM_MANIFEST}"
    fi
    SO_FILES+=("${real}")
done

# NCCL gates. A system library that is bundled must be built for this toolkit's CUDA (a +cuda13.3 libnccl2 in
# a cu134 package is exactly what this refuses). When NCCL comes from a pinned zbrad/nccl release it is linked
# statically, so nothing in the package may need or carry a libnccl.so at all.
if [[ "${#EXTRA_SYSTEM_LIBS[@]}" -gt 0 ]]; then
    gpu_tuned_verify_bundled_cuda_flavor "${CUDA_VER}" "${!EXTRA_SYSTEM_LIBS[@]}" || exit 1
fi
if [[ -n "${LLAMA_TUNED_NCCL_DIR}" ]]; then
    leaked="$(find "${STAGE}" -maxdepth 1 -name 'libnccl*' -print | head -3)"
    [[ -z "${leaked}" ]] || { echo "ERROR: NCCL is linked statically (${LLAMA_TUNED_NCCL_TAG}) but the package carries: ${leaked}" >&2; exit 1; }
    for f in "${STAGE}"/*; do
        [[ -f "${f}" && ! -L "${f}" ]] || continue
        if readelf -d "${f}" 2>/dev/null | grep -q 'Shared library: \[libnccl'; then
            echo "ERROR: $(basename "${f}") still needs a libnccl.so although NCCL ${LLAMA_TUNED_NCCL_VERSION} was to be linked statically; the build did not use ${LLAMA_TUNED_NCCL_DIR}." >&2
            exit 1
        fi
    done
    echo "NCCL ${LLAMA_TUNED_NCCL_VERSION} (zbrad/nccl ${LLAMA_TUNED_NCCL_TAG}) is linked statically; no libnccl.so in the package."
fi

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

# Give every shared object this build produced a unique identity (libggml.so.0 -> libggml-gb10-cu133.so.0,
# file name, SONAME and every DT_NEEDED that names it), so a stock llama.cpp installed beside this one,
# or an LD_LIBRARY_PATH pointing at one, cannot swap libraries with ours in either direction. See
# "unique shared-object identities" in tuned-common's tuned-common.sh. The rename is a patchelf pass
# at staging time; nothing in the upstream-tracked build changes. It assumes backends are LINKED
# libraries: a build with GGML_BACKEND_DL=ON loads them by filename and needs a keep-list instead.
if ! grep -qE '^GGML_BACKEND_DL:BOOL=OFF$' "${BUILD_DIR}/CMakeCache.txt"; then
    echo "ERROR: ${BUILD_DIR} was not configured with GGML_BACKEND_DL=OFF. The shared-object rename assumes" >&2
    echo "  linked backends; dynamic backends are discovered by filename and would stop loading." >&2
    exit 1
fi
echo ""
echo "Giving this build's shared objects unique identities:"
# gpu_tuned_rename_package renames, then fails closed: every shared object is tuned, or a recorded
# bundled system library; every DT_NEEDED resolves inside the stage or is assumed present on the target
# The mark each library takes follows its CONTENTS (docs/ARCHITECTURE.md F1): device code, or a NEEDed variant-named
# library, takes -<variant>-<toolkit> (libggml-cuda, and so libggml, libllama and the tool impls); the rest -<toolkit>.
gpu_tuned_axes_manifest "${STAGE}" "${GPU_TUNED_VARIANT}" "${CUDA_TAG}" "${OURS_MANIFEST}" "${OURS_NAMES[@]}" || exit 1
gpu_tuned_rename_package "${STAGE}" "${OURS_MANIFEST}" "${SYSTEM_MANIFEST}" "" "${ASSUME_PRESENT_RE}"
gpu_tuned_verify_so_axes "${STAGE}" "${GPU_TUNED_VARIANT}" "${CUDA_TAG}" "${SYSTEM_MANIFEST}" || exit 1
# patchelf rewrote the stamped files; prove the stamp survived on the server and on every staged ggml-cuda copy
gpu_tuned_verify_build_info_json "${STAGE}/llama-server-tuned" "release=${RELEASE_TAG}" component=llama-server-tuned "variant=${GPU_TUNED_VARIANT}" "cuda.tag=${CUDA_TAG}" >/dev/null || exit 1
STAGED_CUDA_N=0
for f in "${STAGE}"/libggml-cuda*.so.*; do
    [[ -f "${f}" && ! -L "${f}" ]] || continue
    gpu_tuned_verify_build_info_json "${f}" "release=${RELEASE_TAG}" component=ggml-cuda-tuned >/dev/null || exit 1
    STAGED_CUDA_N=$((STAGED_CUDA_N + 1))
done
[[ ${STAGED_CUDA_N} -ge 1 ]] || { echo "ERROR: no staged libggml-cuda*.so.* after the rename." >&2; exit 1; }
# The same JSON, shipped beside the binaries so install.sh, llmsrv.sh and automation can read the release without readelf.
gpu_tuned_read_build_info "${STAGE}/llama-server-tuned" > "${STAGE}/BUILD_INFO.json" || exit 1

echo ""
echo "Packaging $(basename "${STAGE}")'s $(ls "${STAGE}" | wc -l) files -> ${TARBALL}..."
tar -C "${STAGE}" -czf "${TARBALL}" .
echo "Tarball: $(basename "${TARBALL}") ($(du -sh "${TARBALL}" | awk '{print $1}'))"

# sha256sum-format sidecar (hex digest + filename) -- lets install.sh (and
# anyone else) verify the download before extracting anything, same
# convention goreleaser-style checksums.txt files use.
SHA_FILE="${TARBALL}.sha256"
(cd "${DIST_DIR}" && sha256sum "$(basename "${TARBALL}")" > "$(basename "${SHA_FILE}")")
echo "Checksum: $(basename "${SHA_FILE}") ($(cut -d' ' -f1 "${SHA_FILE}"))"

# --- Check the tarball as a consumer gets it. Any failure leaves no package-info.txt, which
#     release.sh requires. ---
rm -f "${DIST_DIR}/package-info.txt"
echo ""
echo "Checking the tarball:"
PKG_FAILURES=0
pkg_fail() { echo "  FAIL: $*" >&2; PKG_FAILURES=$((PKG_FAILURES + 1)); }
pkg_ok() { echo "  ok:   $*"; }
(cd "${DIST_DIR}" && sha256sum -c --quiet "$(basename "${SHA_FILE}")") && pkg_ok "sha256 sidecar matches" || pkg_fail "sha256 sidecar does not match"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE}" "${OURS_MANIFEST}" "${SYSTEM_MANIFEST}" "${CHECK_DIR}"' EXIT
tar -C "${CHECK_DIR}" -xzf "${TARBALL}"
# Run with the toolkit's own lib dir first: the host's ld.so.conf follows the /usr/local/cuda
# symlink, which can satisfy cudart/cublas from another version.
version_line="$(env LD_LIBRARY_PATH="${GPU_TUNED_TOOLKIT_LIB_DIR}" "${CHECK_DIR}/llama-server-tuned" --version 2>&1 | grep -m1 '^version:' || true)"
release_line="$(env LD_LIBRARY_PATH="${GPU_TUNED_TOOLKIT_LIB_DIR}" "${CHECK_DIR}/llama-server-tuned" --version 2>&1 | grep -m1 '^release:' || true)"
if [[ "${release_line}" == "release: ${RELEASE_TAG}" ]]; then
    pkg_ok "extracted llama-server-tuned prints ${release_line}"
else
    pkg_fail "extracted llama-server-tuned prints '${release_line}', expected 'release: ${RELEASE_TAG}'"
fi
if [[ "${version_line}" == *", commit ${LLAMA_TUNED_BUILD_COMMIT})"* ]]; then
    pkg_ok "extracted llama-server-tuned reports ${version_line#version: }"
else
    pkg_fail "extracted llama-server-tuned reports '${version_line}', expected commit ${LLAMA_TUNED_BUILD_COMMIT}"
fi
for f in "${CHECK_DIR}"/*; do
    [[ -f "${f}" && ! -L "${f}" ]] || continue
    readelf -h "${f}" >/dev/null 2>&1 || continue
    if LD_LIBRARY_PATH="${GPU_TUNED_TOOLKIT_LIB_DIR}" ldd "${f}" 2>&1 | grep -q 'not found'; then
        pkg_fail "$(basename "${f}"): unresolved dependency: $(LD_LIBRARY_PATH="${GPU_TUNED_TOOLKIT_LIB_DIR}" ldd "${f}" 2>&1 | grep 'not found' | head -1 | awk '{print $1}')"
    fi
    gpu_tuned_verify_toolkit_libs "${f}" || PKG_FAILURES=$((PKG_FAILURES + 1))
    rp="$(readelf -d "${f}" 2>/dev/null | sed -n 's/.*(\(RUNPATH\|RPATH\)).*\[\(.*\)\]/\2/p' | head -1)"
    if [[ -n "${rp}" && "${rp}" != '$ORIGIN' ]]; then
        pkg_fail "$(basename "${f}"): RUNPATH is '${rp}', expected \$ORIGIN"
    fi
done
[[ ${PKG_FAILURES} -eq 0 ]] && pkg_ok "every ELF resolves its libraries, RUNPATH is only \$ORIGIN"
if [[ ${PKG_FAILURES} -gt 0 ]]; then
    echo "ERROR: ${PKG_FAILURES} package check(s) failed; not releasable." >&2
    exit 1
fi

# What release.sh needs: the identity the binaries were built with (release.sh runs after notes-only
# commits, when HEAD no longer matches it).
cat > "${DIST_DIR}/package-info.txt" <<INFO
tarball=$(basename "${TARBALL}")
release_tag=${RELEASE_TAG}
build_commit=${LLAMA_TUNED_BUILD_COMMIT}
cuda_tag=${CUDA_TAG}
variant=${GPU_TUNED_VARIANT}
sha256=$(cut -d" " -f1 "${SHA_FILE}")
INFO

# --- Draft release notes, only if none exist yet. They are a tracked file, reviewed and committed
#     (a notes-only commit) before release.sh; the DRAFT line must be removed first. ---
# Redact any real hostname the notes text might mention, per a local,
# gitignored mapping (tuned/hostname-aliases.local -- see the .example
# file next to it). No-op if that file doesn't exist, so a fresh
# checkout with nothing configured yet still publishes fine -- this is
# a safety net, not a hard requirement.
redact_hostnames() {
    local text="$1"
    local map="${REPODIR}/tuned/hostname-aliases.local"
    [[ -f "${map}" ]] || { echo "${text}"; return; }
    while IFS='=' read -r real alias; do
        [[ -z "${real}" || "${real}" == \#* ]] && continue
        text="${text//${real}/${alias}}"
    done < "${map}"
    echo "${text}"
}

NOTES_FILE="${REPODIR}/tuned/releases/RELEASE_NOTES_${RELEASE_TAG#v}.md"
if [[ -f "${NOTES_FILE}" ]]; then
    echo "Release notes exist: ${NOTES_FILE}"
else
    mkdir -p "${REPODIR}/tuned/releases"
    COMPAT_NOTES="$(bash "${REPODIR}/tuned/compat-notes.sh" "${GPU_TUNED_VARIANT}" "${CHECK_DIR}")"
    {
        echo "<!-- DRAFT — not yet published: review, then delete this line and commit -->"
        redact_hostnames "llama-server-tuned + llama-quantize-tuned + $(( ${#SO_FILES[@]} )) shared libraries, single-arch (sm_${GPU_TUNED_CUDA_ARCH}), built against CUDA ${CUDA_VER}. Includes the Ollama-format GGUF compatibility shim. Web UI: ${UI_BUILD% *} (audited dependency set, tarball sha256 ${UI_BUILD#* }). Easiest setup: curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash -- fetches this release, models/aliases.json, and llmsrv.sh for you (that URL always has the current installer; it takes the helper files from this release's own tag). To deploy into an Ollama installation instead, see zbrad/ollama's tuned-builds fetch script, or manually: extract and copy llama-server + libs to your Ollama lib directory, symlinking llama-server into place (see zbrad/ollama's docs/local-llama-cpp.md)."
        echo ""
        echo "NCCL ${LLAMA_TUNED_NCCL_VERSION}: $([[ -n "${LLAMA_TUNED_NCCL_DIR}" ]] && echo "from zbrad/nccl ${LLAMA_TUNED_NCCL_TAG}, built for ${CUDA_TAG}, linked statically into libggml-cuda; no libnccl.so is shipped or needed" || echo "the system libnccl2 this toolkit pins, bundled in the package")."
        echo ""
        if [[ -f "${BUILD_DIR}/relabel.json" ]] && grep -q "\"to\":\"${RELEASE_TAG}\"" "${BUILD_DIR}/relabel.json"; then
            echo "Tested: the ctest suite passed (log attached) on the same commit built as $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["from"])' "${BUILD_DIR}/relabel.json"); this release was relabelled from it without rerunning the suite, after tuned/relabel.sh showed the rebuilt binaries differ from the tested ones only in the release label (section-by-section comparison of every ELF file). The tarball was checked as extracted (version, ldd, RUNPATH, toolkit libraries) and installed with install.sh."
        else
            echo "Tested: the ctest suite passed on this build (log attached), and the tarball was checked as extracted (version, ldd, RUNPATH, toolkit libraries)."
        fi
        echo ""
        echo "${COMPAT_NOTES}"
    } > "${NOTES_FILE}"
    echo "Wrote a DRAFT: ${NOTES_FILE}"
fi

echo ""
echo "Packaged ${TARBALL}. Not released: run tuned/smoke_test.sh ${GPU_TUNED_VARIANT} (installs it and uses it), review/commit the notes, then tuned/release.sh ${GPU_TUNED_VARIANT}."

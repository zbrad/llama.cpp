#!/bin/bash
# tuned/release.sh <variant> [--publish] [--preflight-only] [--skip-build]
#
# Orchestrates a tuned release: preflight gates -> build -> package ->
# verify -> (only with --publish) tag + push + publish. Without --publish
# it is a dry run: everything up to and including verification really runs,
# but nothing is tagged, pushed or published.
#
# Two things get released together:
#   - the source tag  tuning-YYYYMMDD   (what install.sh's REPO_REF pins)
#   - the binary release  v<build>-<variant>-<cuda>  (what install.sh fetches)
#
# The source tag name is NOT computed here. It is read from install.sh's
# REPO_REF default, which is bumped by hand and committed before releasing,
# so the tagged commit contains the pin that names its own tag. Gates check
# that the pin is well formed, dated today, and not already taken.
#
# The CUDA toolkit comes from tuned/common-data/toolkits (set CUDA_TAG=cu133 or
# CUDA_VER=13.3 to choose). With neither set, env.sh uses the highest defined
# toolkit and prints the available list and why; the cuNNN suffix of the
# release name follows from it. The CMake flags come from tuned/repo.env.
#
#   bash tuned/release.sh gb10                               # dry run
#   CUDA_TAG=cu133 bash tuned/release.sh gb10 --publish      # for real
#   bash tuned/release.sh gb10 --preflight-only
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT=""
PUBLISH=0
PREFLIGHT_ONLY=0
SKIP_BUILD=0
for arg in "$@"; do
    case "${arg}" in
        --publish) PUBLISH=1 ;;
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        -*) echo "ERROR: unknown option ${arg}" >&2; exit 2 ;;
        *) VARIANT="${arg}" ;;
    esac
done
[[ -n "${VARIANT}" ]] || { echo "usage: tuned/release.sh <variant> [--publish] [--preflight-only] [--skip-build]" >&2; exit 2; }

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${VARIANT}" || exit 1

REPO="zbrad/llama.cpp"
BRANCH="tuned-builds"
BUILD_DIR="${LLAMA_TUNED_BUILD_DIR:-${REPODIR}/build}"
DIST_DIR="${REPODIR}/dist/${GPU_TUNED_VARIANT}"
BIN_TAG="v${LLAMA_TUNED_BUILD_NUMBER}-${GPU_TUNED_VARIANT}-${CUDA_TAG}"
SRC_TAG="$(sed -n 's/^REPO_REF="\${REPO_REF:-\(.*\)}"$/\1/p' "${REPODIR}/install.sh" | head -1)"

echo "===================================================="
echo "llama.cpp ${GPU_TUNED_HW_LABEL} Release  ($([[ ${PUBLISH} -eq 1 ]] && echo PUBLISH || echo "dry run"))"
echo "===================================================="
echo "  Source tag  : ${SRC_TAG:-<not found in install.sh>}"
echo "  Binary tag  : ${BIN_TAG}"
echo "  Build       : ${LLAMA_TUNED_BUILD_NUMBER} (${LLAMA_TUNED_BUILD_COMMIT})"
echo "  CUDA        : ${CUDA_TAG}"
echo ""

# --- Preflight gates: run all of them, report every failure, then stop. ---
FAILURES=0
fail() { echo "  FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok:   $*"; }

echo "Preflight:"
if [[ -z "$(git -C "${REPODIR}" status --porcelain)" ]]; then
    ok "working tree clean"
else
    fail "working tree is not clean (commit, stash or remove changes first)"
fi

if [[ "$(git -C "${REPODIR}" rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]]; then
    ok "on branch ${BRANCH}"
else
    fail "not on branch ${BRANCH}"
fi

if git -C "${REPODIR}" fetch origin "${BRANCH}" --tags --quiet 2>/dev/null; then
    if [[ "$(git -C "${REPODIR}" rev-parse HEAD)" == "$(git -C "${REPODIR}" rev-parse "origin/${BRANCH}")" ]]; then
        ok "HEAD == origin/${BRANCH} (the release --target)"
    else
        fail "HEAD differs from origin/${BRANCH}; push or pull first"
    fi
else
    fail "could not fetch origin/${BRANCH}"
fi

if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated"
else
    fail "gh is not authenticated"
fi

if [[ "${SRC_TAG}" =~ ^tuning-([0-9]{8})$ ]]; then
    if [[ "${BASH_REMATCH[1]}" == "$(date +%Y%m%d)" ]]; then
        ok "install.sh pin ${SRC_TAG} is dated today"
    else
        fail "install.sh pin ${SRC_TAG} is not dated today ($(date +%Y%m%d)); re-bump REPO_REF and commit"
    fi
    if git -C "${REPODIR}" rev-parse -q --verify "refs/tags/${SRC_TAG}" >/dev/null \
        || [[ -n "$(git -C "${REPODIR}" ls-remote --tags origin "${SRC_TAG}")" ]]; then
        fail "source tag ${SRC_TAG} already exists locally or on origin"
    else
        ok "source tag ${SRC_TAG} is free"
    fi
else
    fail "install.sh REPO_REF '${SRC_TAG}' is not of the form tuning-YYYYMMDD"
fi

if gh release view "${BIN_TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    fail "binary release ${BIN_TAG} already exists"
else
    ok "binary release ${BIN_TAG} is free"
fi

if gpu_tuned_verify_toolkit >/dev/null; then
    ok "toolkit ${CUDA_TAG} verified: nvcc and libnccl2 match its definition (${CUDA_HOME})"
else
    fail "toolkit ${CUDA_TAG} does not match its definition; run gpu_tuned_verify_toolkit for details"
fi

if [[ -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
    cached_nvcc="$(sed -n 's/^CMAKE_CUDA_COMPILER:[A-Z]*=//p' "${BUILD_DIR}/CMakeCache.txt")"
    if [[ -n "${cached_nvcc}" && "${cached_nvcc}" != "${CUDA_HOME}/bin/nvcc" ]]; then
        fail "${BUILD_DIR} was configured with ${cached_nvcc}, not ${CUDA_HOME}/bin/nvcc; use another LLAMA_TUNED_BUILD_DIR or remove it yourself"
    else
        ok "build dir CUDA compiler matches ${CUDA_VER}"
    fi
fi

if [[ ${FAILURES} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: ${FAILURES} preflight gate(s) failed; nothing was built." >&2
    exit 1
fi
if [[ ${PREFLIGHT_ONLY} -eq 1 ]]; then
    echo ""
    echo "Preflight passed (--preflight-only)."
    exit 0
fi

# --- Build ---
if [[ ${SKIP_BUILD} -eq 0 ]]; then
    echo ""
    echo "Building (CUDA ${CUDA_VER}, sm_${GPU_TUNED_CUDA_ARCH})..."
    # CMake takes the bare arch (121) and upgrades it to 121a itself.
    cmake -S "${REPODIR}" -B "${BUILD_DIR}" "${LLAMA_TUNED_CMAKE_FLAGS[@]}" \
        -DCMAKE_CUDA_COMPILER="${CUDA_HOME}/bin/nvcc" \
        -DCMAKE_CUDA_ARCHITECTURES="${GPU_TUNED_CUDA_ARCH//[a-z]/}"
    cmake --build "${BUILD_DIR}" --config Release -j"$(gpu_tuned_jobs)"
fi

# --- Package (no publish) ---
echo ""
LLAMA_TUNED_NO_PUBLISH=1 bash "${REPODIR}/tuned/package.sh" "${VARIANT}"

# --- Verify what was packaged ---
echo ""
echo "Verify:"
TARBALL="$(ls "${DIST_DIR}"/llama-cpp-*.tar.gz)"
(cd "${DIST_DIR}" && sha256sum -c "$(basename "${TARBALL}").sha256" >/dev/null) \
    && ok "sha256 sidecar matches" || fail "sha256 sidecar does not match"

CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "${CHECK_DIR}"' EXIT
tar -C "${CHECK_DIR}" -xzf "${TARBALL}"

# Run with the toolkit's own lib dir first: the host's ld.so.conf follows the
# /usr/local/cuda symlink, which can satisfy cudart/cublas from another version.
version_line="$(env LD_LIBRARY_PATH="${GPU_TUNED_TOOLKIT_LIB_DIR}" "${CHECK_DIR}/llama-server-tuned" --version 2>&1 | grep -m1 '^version:' || true)"
if [[ "${version_line}" == *"${LLAMA_TUNED_BUILD_NUMBER} (${LLAMA_TUNED_BUILD_COMMIT}"* ]]; then
    ok "extracted llama-server-tuned reports ${version_line#version: }"
else
    fail "extracted llama-server-tuned reports '${version_line}', expected ${LLAMA_TUNED_BUILD_NUMBER} (${LLAMA_TUNED_BUILD_COMMIT})"
fi

for f in "${CHECK_DIR}"/*; do
    [[ -f "${f}" && ! -L "${f}" ]] || continue
    readelf -h "${f}" >/dev/null 2>&1 || continue
    if LD_LIBRARY_PATH="${GPU_TUNED_TOOLKIT_LIB_DIR}" ldd "${f}" 2>&1 | grep -q 'not found'; then
        fail "$(basename "${f}"): unresolved dependency: $(LD_LIBRARY_PATH="${GPU_TUNED_TOOLKIT_LIB_DIR}" ldd "${f}" 2>&1 | grep 'not found' | head -1 | awk '{print $1}')"
    fi
    gpu_tuned_verify_toolkit_libs "${f}" || FAILURES=$((FAILURES + 1))
    rp="$(readelf -d "${f}" 2>/dev/null | grep -oP '(?<=\((RUNPATH|RPATH)\)\s{1,10}Library (runpath|rpath): \[)[^\]]+' || true)"
    if [[ -n "${rp}" && "${rp}" != '$ORIGIN' ]]; then
        fail "$(basename "${f}"): RUNPATH is '${rp}', expected \$ORIGIN"
    fi
done
[[ ${FAILURES} -eq 0 ]] && ok "every ELF resolves its libraries, RUNPATH is only \$ORIGIN"

if [[ ${FAILURES} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: ${FAILURES} verification check(s) failed; nothing was tagged or published." >&2
    exit 1
fi

# --- Publish (only with --publish) ---
echo ""
if [[ ${PUBLISH} -eq 0 ]]; then
    echo "Dry run complete. With --publish this would:"
    echo "  git tag ${SRC_TAG} $(git -C "${REPODIR}" rev-parse --short HEAD) && git push origin ${SRC_TAG}"
    echo "  gh release create ${BIN_TAG} (target ${BRANCH}) with $(basename "${TARBALL}") + .sha256"
    echo "Artifacts: ${DIST_DIR}"
    exit 0
fi

echo "Tagging and publishing..."
git -C "${REPODIR}" tag "${SRC_TAG}" HEAD
git -C "${REPODIR}" push origin "${SRC_TAG}"
gpu_tuned_publish_release "${REPO}" "${BIN_TAG}" "$(cat "${DIST_DIR}/release-title.txt")" \
    "@${DIST_DIR}/release-notes.md" \
    "${TARBALL}#$(basename "${TARBALL}")" \
    "${TARBALL}.sha256#$(basename "${TARBALL}").sha256"
echo ""
echo "Done: https://github.com/${REPO}/releases/tag/${BIN_TAG}"

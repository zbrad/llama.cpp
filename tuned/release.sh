#!/bin/bash
# tuned/release.sh <variant> [--preflight-only] — run the release gates for the tarball tuned/package.sh made.
# It NEVER publishes or tags. When every gate passes it writes a ready-marker (gpu_tuned_release_ready); then
# tuned/publish.sh <variant> publishes exactly what these gates saw, and refuses if HEAD, the notes or an asset changed.
#   tuned/build.sh -> tuned/full_test.sh -> tuned/package.sh -> tuned/smoke_test.sh
#   -> (review + commit the notes) -> this -> tuned/publish.sh.
#
# Gates: preflight (branch, HEAD == origin, gh, toolkit, tag free); a passing full_test.sh log newer
# than the build (or a relabel record from tuned/relabel.sh proving the build differs from the tested one only
# in its release label); then gpu_tuned_release_gates (tuned-common): clean tree, HEAD pushed, tarball matches its
# package-info and .sha256, made after the tests, a passing smoke test (install.sh run on that tarball) newer than
# it, only release notes changed since the package's commit, notes committed and not a DRAFT.
#
# One identity per release: the date label package.sh allocated (UTC date of HEAD's commit plus a sequence
# for that date), as the native tag v0.<date>.<seq>-<variant>-<cuda>, recorded in package-info.txt, so a
# notes-only commit after packaging does not change it. gh creates that tag on the tuned-builds head (at
# publish), and install.sh fetches llmsrv.sh and models/aliases.json from it: there is no separate source tag
# and no pin to bump. The build number is only what llama-server --version reports. The CUDA toolkit is chosen as in
# build.sh (CUDA_TAG / CUDA_VER).
#
#   CUDA_TAG=cu133 bash tuned/release.sh gb10      # gates; writes the ready-marker if all pass
#   CUDA_TAG=cu133 bash tuned/publish.sh gb10      # publishes from the marker
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT=""
PREFLIGHT_ONLY=0
for arg in "$@"; do
    case "${arg}" in
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        -*) echo "ERROR: unknown option ${arg}" >&2; exit 2 ;;
        *) VARIANT="${arg}" ;;
    esac
done
[[ -n "${VARIANT}" ]] || { echo "usage: tuned/release.sh <variant> [--preflight-only]" >&2; exit 2; }

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${VARIANT}" || exit 1

# The build identity comes from the package, not HEAD: notes-only commits after packaging move HEAD.
# (env.sh only defaults LLAMA_TUNED_BUILD_COMMIT to HEAD; the package's value replaces it here.)
PKG_INFO="${LLAMA_TUNED_DIST_DIR}/package-info.txt"
if [[ -f "${PKG_INFO}" ]]; then
    BIN_TAG="$(sed -n 's/^release_tag=//p' "${PKG_INFO}")"
    LLAMA_TUNED_BUILD_COMMIT="$(sed -n 's/^build_commit=//p' "${PKG_INFO}")"
    export LLAMA_TUNED_BUILD_COMMIT
fi

REPO="zbrad/llama.cpp"
READY_MARKER="${LLAMA_TUNED_RELEASES_DIR}/RELEASE_READY_${GPU_TUNED_VARIANT}"
gpu_tuned_release_marker_clear "${READY_MARKER}"   # a failing run leaves no marker
BRANCH="tuned-builds"
BUILD_DIR="${LLAMA_TUNED_BUILD_DIR}"   # from env.sh: tuned/build/<cuda-tag>/cmake
DIST_DIR="${LLAMA_TUNED_DIST_DIR}"
BIN_TAG="${BIN_TAG:-}"   # from package-info.txt; the date label was allocated when packaging

echo "===================================================="
echo "llama.cpp ${GPU_TUNED_HW_LABEL} release gates  (never publishes)"
echo "===================================================="
echo "  Binary tag  : ${BIN_TAG:-<no package yet>}"
echo "  Commit      : ${LLAMA_TUNED_BUILD_COMMIT}"
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

if [[ -z "${BIN_TAG}" ]]; then
    fail "no package-info.txt, so no release tag; run tuned/package.sh ${VARIANT}"
elif ! gpu_tuned_check_release_tag "${BIN_TAG}" 2>/dev/null; then
    fail "release tag ${BIN_TAG} carries no date label (v0.<YYYYMMDD>.<seq>-<variant>-<cuda>)"
elif gh release view "${BIN_TAG}" --repo "${REPO}" >/dev/null 2>&1; then
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

if [[ ${PREFLIGHT_ONLY} -eq 1 ]]; then
    if [[ ${FAILURES} -gt 0 ]]; then
        echo "" >&2
        echo "ERROR: ${FAILURES} preflight gate(s) failed." >&2
        exit 1
    fi
    echo ""
    echo "Preflight passed (--preflight-only)."
    exit 0
fi

# --- Test gate: a passing tuned/full_test.sh log, newer than everything the build produced. This
#     script never runs the tests, so a release can't pass on a log from an earlier build or
#     another toolkit (the log lives in the toolkit's own build tree). ---
echo ""
echo "Gates:"
if [[ ! -f "${LLAMA_TUNED_TEST_LOG}" ]]; then
    fail "${LLAMA_TUNED_TEST_LOG} not found; run tuned/full_test.sh ${VARIANT}"
else
    newer="$(find "${BUILD_DIR}/bin" -maxdepth 1 -type f \( -name 'llama-*' -o -name 'lib*.so*' \) -newer "${LLAMA_TUNED_TEST_LOG}" -print -quit)"
    RELABEL="${BUILD_DIR}/relabel.json"
    if ! grep -q "Full test suite summary: ctest passed" "${LLAMA_TUNED_TEST_LOG}"; then
        fail "${LLAMA_TUNED_TEST_LOG} does not show a clean pass"
    elif [[ -z "${newer}" ]]; then
        ok "full test suite passed, log newer than the build"
    elif [[ -f "${RELABEL}" ]] && [[ -z "$(find "${BUILD_DIR}/bin" -maxdepth 1 -type f \( -name 'llama-*' -o -name 'lib*.so*' \) -newer "${RELABEL}" -print -quit)" ]] \
        && python3 - "${RELABEL}" "${BIN_TAG}" "$(sha256sum "${LLAMA_TUNED_TEST_LOG}" | awk '{print $1}')" "$(sed -n 's/^commit: *\([0-9a-f]*\).*/\1/p' "${LLAMA_TUNED_TEST_LOG}" | head -1)" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
ok = (rec.get("to") == sys.argv[2] and rec.get("test_log_sha256") == sys.argv[3] and rec.get("commit") == sys.argv[4])
sys.exit(0 if ok else 1)
PY
    then
        ok "relabelled build: tuned/relabel.sh showed the binaries differ from the tested build only in the label ($(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["from"], "->", r["to"])' "${RELABEL}")); the full suite log is that of the original label"
    else
        fail "${newer} is newer than the test log and there is no valid relabel record for ${BIN_TAG}; re-run tuned/full_test.sh ${VARIANT} (or tuned/relabel.sh if only the label changed)"
    fi
fi

# --- Common gates (tuned-common): clean tree, HEAD pushed, tarball vs package-info and .sha256, tarball after the
#     tests, smoke test, only notes changed since the packaged commit, notes committed and not a DRAFT. The test
#     freshness against the binaries is the gate above (it has the relabel case), so no built= is passed. ---
cd "${REPODIR}"
TARBALL=""
SMOKE_LOG="${LLAMA_TUNED_RELEASES_DIR}/SMOKE_RESULTS_${GPU_TUNED_VARIANT}.log"
NOTES_FILE="tuned/releases/RELEASE_NOTES_${BIN_TAG#v}.md"
if [[ ! -f "${PKG_INFO}" ]]; then
    fail "${PKG_INFO} not found; run tuned/package.sh ${VARIANT}"
else
    TARBALL="${DIST_DIR}/$(sed -n 's/^tarball=//p' "${PKG_INFO}")"
    gpu_tuned_release_gates tag="${BIN_TAG}" variant="${GPU_TUNED_VARIANT}" cuda="${CUDA_TAG}" info="${PKG_INFO}" \
        test_log="${LLAMA_TUNED_TEST_LOG}" "test_pass=Full test suite summary: ctest passed" \
        tarball="${TARBALL}" smoke_log="${SMOKE_LOG}" notes="${NOTES_FILE}" packaged="${LLAMA_TUNED_BUILD_COMMIT}" \
        || FAILURES=$((FAILURES + 1))
fi
if [[ ${FAILURES} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: ${FAILURES} gate(s) failed (preflight, test, package, notes); nothing was tagged or published, no ready-marker written." >&2
    exit 1
fi

RELEASE_TITLE="llama.cpp ${BIN_TAG#v} (${LLAMA_TUNED_BUILD_COMMIT}) — ${GPU_TUNED_HW_LABEL} (${CUDA_TAG})"

echo ""
gpu_tuned_release_ready "${READY_MARKER}" "${REPO}" "${BIN_TAG}" "${RELEASE_TITLE}" "${NOTES_FILE}" \
    "${TARBALL}#$(basename "${TARBALL}")" \
    "${TARBALL}.sha256#$(basename "${TARBALL}").sha256" \
    "${LLAMA_TUNED_TEST_LOG}#Full test suite results (${GPU_TUNED_VARIANT})" \
    "${SMOKE_LOG}#Package install and smoke test results (${GPU_TUNED_VARIANT})"

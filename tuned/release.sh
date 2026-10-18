#!/bin/bash
# tuned/release.sh <variant> [--publish] [--preflight-only] — publish the tarball tuned/package.sh
# made, with the tracked release notes, after the gates. Same split as raft, cuvs and faiss:
#   tuned/build.sh -> tuned/full_test.sh -> tuned/package.sh -> tuned/smoke_test.sh
#   -> (review + commit the notes) -> this.
# Without --publish it is a dry run: every gate really runs, nothing is published.
#
# Gates: preflight (clean tree, branch, origin, gh, toolkit, tag free); a passing full_test.sh log newer
# than the build (or a relabel record from tuned/relabel.sh proving the build differs from the tested one only
# in its release label); a package made from that build after the tests; a passing smoke test (install.sh run on
# that tarball) newer than it; only release notes changed since the package's commit; the notes are not a
# DRAFT.
#
# One identity per release: the date label package.sh allocated (UTC date of HEAD's commit plus a sequence
# for that date), as the native tag v0.<date>.<seq>-<variant>-<cuda>, recorded in package-info.txt, so a
# notes-only commit after packaging does not change it. gh creates that tag on the tuned-builds head, and
# install.sh fetches llmsrv.sh and models/aliases.json from it: there is no separate source tag and no pin to
# bump. The build number is only what llama-server --version reports. The CUDA toolkit is chosen as in
# build.sh (CUDA_TAG / CUDA_VER).
#
#   CUDA_TAG=cu133 bash tuned/release.sh gb10                # dry run
#   CUDA_TAG=cu133 bash tuned/release.sh gb10 --publish      # for real
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT=""
PUBLISH=0
PREFLIGHT_ONLY=0
for arg in "$@"; do
    case "${arg}" in
        --publish) PUBLISH=1 ;;
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        -*) echo "ERROR: unknown option ${arg}" >&2; exit 2 ;;
        *) VARIANT="${arg}" ;;
    esac
done
[[ -n "${VARIANT}" ]] || { echo "usage: tuned/release.sh <variant> [--publish] [--preflight-only]" >&2; exit 2; }

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
BRANCH="tuned-builds"
BUILD_DIR="${LLAMA_TUNED_BUILD_DIR}"   # from env.sh: tuned/build/<cuda-tag>/cmake
DIST_DIR="${LLAMA_TUNED_DIST_DIR}"
BIN_TAG="${BIN_TAG:-}"   # from package-info.txt; the date label was allocated when packaging

echo "===================================================="
echo "llama.cpp ${GPU_TUNED_HW_LABEL} Release  ($([[ ${PUBLISH} -eq 1 ]] && echo PUBLISH || echo "dry run"))"
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

# --- Package gate: made from this build after the tests, and nothing but release notes changed
#     since the commit it was built from. ---
TARBALL=""
if [[ ! -f "${PKG_INFO}" ]]; then
    fail "${PKG_INFO} not found; run tuned/package.sh ${VARIANT}"
else
    TARBALL="${DIST_DIR}/$(sed -n 's/^tarball=//p' "${PKG_INFO}")"
    grep -qxF "cuda_tag=${CUDA_TAG}" "${PKG_INFO}" || fail "package-info.txt is for another toolkit than ${CUDA_TAG}"
    if [[ ! -f "${TARBALL}" || ! -f "${TARBALL}.sha256" ]]; then
        fail "${TARBALL} or its .sha256 not found; run tuned/package.sh ${VARIANT}"
    else
        (cd "${DIST_DIR}" && sha256sum -c --quiet "$(basename "${TARBALL}").sha256") && ok "tarball matches its .sha256" || fail "tarball does not match its .sha256"
        if [[ "${LLAMA_TUNED_TEST_LOG}" -nt "${TARBALL}" ]]; then
            fail "the test log is newer than the tarball; package again after testing (tuned/package.sh ${VARIANT})"
        else
            ok "tarball was made after the tests"
        fi
        SMOKE_LOG="${LLAMA_TUNED_RELEASES_DIR}/SMOKE_RESULTS_${GPU_TUNED_VARIANT}.log"
        if [[ ! -f "${SMOKE_LOG}" ]]; then
            fail "${SMOKE_LOG} not found; run tuned/smoke_test.sh ${VARIANT}"
        elif [[ "${TARBALL}" -nt "${SMOKE_LOG}" ]]; then
            fail "${TARBALL} is newer than the smoke test log; re-run tuned/smoke_test.sh ${VARIANT}"
        elif ! grep -q "Smoke test summary: passed" "${SMOKE_LOG}"; then
            fail "${SMOKE_LOG} does not show a pass"
        else
            ok "smoke test (install.sh on this tarball) passed"
        fi
    fi
    changed="$(git -C "${REPODIR}" diff --name-only "${LLAMA_TUNED_BUILD_COMMIT}" HEAD -- . ':!tuned/releases' 2>/dev/null || echo "?")"
    if [[ -n "${changed}" ]]; then
        fail "files other than tuned/releases/ changed since the packaged commit ${LLAMA_TUNED_BUILD_COMMIT}: $(echo "${changed}" | head -3 | tr '\n' ' ')"
    else
        ok "only release notes changed since the packaged commit ${LLAMA_TUNED_BUILD_COMMIT}"
    fi
fi

# --- Release notes: a tracked, reviewed file; not a draft. ---
NOTES_FILE="${REPODIR}/tuned/releases/RELEASE_NOTES_${BIN_TAG#v}.md"
if [[ ! -f "${NOTES_FILE}" ]]; then
    fail "${NOTES_FILE} not found; tuned/package.sh writes a draft"
elif grep -q 'DRAFT — not yet published' "${NOTES_FILE}"; then
    fail "${NOTES_FILE} is still a draft (DRAFT line present)"
else
    ok "release notes ${NOTES_FILE##*/} reviewed"
fi
if [[ ${FAILURES} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: ${FAILURES} gate(s) failed (preflight, test, package, notes); nothing was tagged or published." >&2
    exit 1
fi

RELEASE_TITLE="llama.cpp ${BIN_TAG#v} (${LLAMA_TUNED_BUILD_COMMIT}) — ${GPU_TUNED_HW_LABEL} (${CUDA_TAG})"

# --- Publish (only with --publish) ---
echo ""
if [[ ${PUBLISH} -eq 0 ]]; then
    echo "Dry run complete. With --publish this would:"
    echo "  gh release create ${BIN_TAG} (target ${BRANCH}), notes ${NOTES_FILE##*/}, with $(basename "${TARBALL}"), its .sha256 and the test log"
    exit 0
fi

echo "Publishing..."
gpu_tuned_publish_release "${REPO}" "${BIN_TAG}" "${RELEASE_TITLE}" \
    "@${NOTES_FILE}" \
    "${TARBALL}#$(basename "${TARBALL}")" \
    "${TARBALL}.sha256#$(basename "${TARBALL}").sha256" \
    "${LLAMA_TUNED_TEST_LOG}#Full test suite results (${GPU_TUNED_VARIANT})" \
    "${SMOKE_LOG}#Package install and smoke test results (${GPU_TUNED_VARIANT})"
echo ""
echo "Done: https://github.com/${REPO}/releases/tag/${BIN_TAG}"

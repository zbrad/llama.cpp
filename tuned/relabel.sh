#!/bin/bash
# tuned/relabel.sh <variant> — give a tested build a new release label without rerunning the test suite,
# when (and only when) the rebuilt binaries are provably the same code.
#
# Why it exists: the release label is compiled into the binary (common/build-info.cpp.in, shown by
# `llama-server --version`) at build time, but nothing reserves a label until it is published. If the label a
# build carries has been taken since (another build was released first), the build needs a new one. That changes
# one 64-byte buffer and nothing else, so the full suite need not run again — provided this script can show it.
#
# What it does, in order:
#   1. checks the build is the tested one: a passing full_test.sh log newer than the build, run at HEAD;
#   2. snapshots every ELF file in <build>/bin section by section (sha256), with the label buffer masked;
#   3. rebuilds with tuned/build.sh, which allocates the next free label and compiles it in;
#   4. snapshots again and compares (tuned/elf_section_diff.py): only the label bytes and derived sections (the
#      build id) may differ; any moved symbol, resized or changed section is a refusal;
#   5. writes <build>/relabel.json, which tuned/release.sh accepts in place of a log newer than the build.
# It does not package or release: run tuned/package.sh and tuned/smoke_test.sh next, as usual. On a refusal the
# new build stays in place and the old test log no longer covers it: run tuned/full_test.sh.
#
#   CUDA_TAG=cu133 bash tuned/relabel.sh gb10
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/relabel.sh <variant>}"

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

BUILD_DIR="${LLAMA_TUNED_BUILD_DIR}"
BIN_DIR="${BUILD_DIR}/bin"
TEST_LOG="${LLAMA_TUNED_TEST_LOG}"
DIFF_TOOL="${REPODIR}/tuned/elf_section_diff.py"
die() { echo "ERROR (relabel): $*" >&2; exit 1; }

[[ -f "${BUILD_DIR}/release-label" ]] || die "${BUILD_DIR}/release-label not found; run tuned/build.sh ${GPU_TUNED_VARIANT} first."
OLD_TAG="$(head -1 "${BUILD_DIR}/release-label")"

# 1. the build is the tested one
[[ -f "${TEST_LOG}" ]] || die "${TEST_LOG} not found; there is no tested build to relabel. Run tuned/full_test.sh."
grep -q "Full test suite summary: ctest passed" "${TEST_LOG}" || die "${TEST_LOG} does not show a clean pass."
newer="$(find "${BIN_DIR}" -maxdepth 1 -type f \( -name 'llama-*' -o -name 'lib*.so*' \) -newer "${TEST_LOG}" -print -quit)"
[[ -z "${newer}" ]] || die "${newer} is newer than the test log: this build was not tested. Run tuned/full_test.sh."
TESTED_COMMIT="$(sed -n 's/^commit: *\([0-9a-f]*\).*/\1/p' "${TEST_LOG}" | head -1)"
[[ "${TESTED_COMMIT}" == "${LLAMA_TUNED_BUILD_COMMIT}" ]] || die "the tests ran at ${TESTED_COMMIT}, HEAD is ${LLAMA_TUNED_BUILD_COMMIT}: relabelling is for the same commit only."
[[ -z "$(git -C "${REPODIR}" status --porcelain --untracked-files=no)" ]] || die "the working tree is not clean; a relabel is for a committed build."

# the next free label must differ from the one the build carries
NEW_LABEL="$(gpu_tuned_allocate_date_label "${REPODIR}")" || exit 1
NEW_TAG="$(gpu_tuned_native_tag "${GPU_TUNED_VARIANT}" "${CUDA_TAG}" "${NEW_LABEL}")" || exit 1
[[ "${NEW_TAG}" != "${OLD_TAG}" ]] || die "${OLD_TAG} is still free; nothing to relabel."
echo "Relabel ${OLD_TAG} -> ${NEW_TAG} (tested at ${TESTED_COMMIT})"

# 2. snapshot the tested build
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
python3 "${DIFF_TOOL}" snapshot "${BIN_DIR}" "${WORK}/before.json"
TEST_LOG_SHA="$(sha256sum "${TEST_LOG}" | awk '{print $1}')"

# 3. rebuild (build.sh allocates NEW_TAG itself: the allocator is deterministic until something is published)
bash "${REPODIR}/tuned/build.sh" "${GPU_TUNED_VARIANT}"
[[ "$(head -1 "${BUILD_DIR}/release-label")" == "${NEW_TAG}" ]] || die "build.sh recorded $(head -1 "${BUILD_DIR}/release-label"), expected ${NEW_TAG}."

# 4. snapshot again and compare
python3 "${DIFF_TOOL}" snapshot "${BIN_DIR}" "${WORK}/after.json"
if ! python3 "${DIFF_TOOL}" compare "${WORK}/before.json" "${WORK}/after.json" "${NEW_TAG}"; then
    rm -f "${BUILD_DIR}/relabel.json"
    die "the rebuild differs from the tested build by more than the label; the old test log does not cover it. Run tuned/full_test.sh ${GPU_TUNED_VARIANT}."
fi

# 5. record it
cat > "${BUILD_DIR}/relabel.json" <<JSON
{"schema":"tuned-relabel/1","from":"${OLD_TAG}","to":"${NEW_TAG}","commit":"${TESTED_COMMIT}","test_log_sha256":"${TEST_LOG_SHA}","files":$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${WORK}/after.json"),"compared_by":"tuned/elf_section_diff.py","relabelled":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
echo "Relabelled: ${OLD_TAG} -> ${NEW_TAG}. Next: tuned/package.sh ${GPU_TUNED_VARIANT}, then tuned/smoke_test.sh ${GPU_TUNED_VARIANT}."

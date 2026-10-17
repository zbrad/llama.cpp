#!/bin/bash
# tuned/smoke_test.sh <variant> — install the PACKAGED tarball the way a user would, and use it, before
# anything is released. Stage order: build -> full_test -> package -> (install + smoke, this) -> release.
#
# It runs install.sh against the local package (LLAMA_CPP_LOCAL_TARBALL, with the helper files copied from
# this checkout, so no GitHub access and nothing published) into a scratch directory, and checks:
#   1. the tarball's sha256 matches package-info.txt;
#   2. install.sh itself succeeds: it verifies the sidecar checksum, extracts, checks that every library
#      resolves and llama-server sees a CUDA device, and serves a completion from a ~1 MB model;
#   3. the installed llama-server-tuned reports the build number and commit this checkout derives for the
#      package, its JSON build info names this release (and BUILD_INFO.json is that same stamp), and every library it needs resolves to a file inside the install directory (not the build
#      tree, not a stock llama.cpp);
#   4. the installed llmsrv.sh and models/aliases.json are the ones in this checkout.
# A smoke test, not the suite: tuned/full_test.sh already ran every ctest against the build tree. What is
# new here is that the files a user gets are the ones running. Needs network access for the ~1 MB model
# (install.sh's own check). Writes dist/<variant>/SMOKE_RESULTS_<variant>.log; tuned/release.sh requires a
# passing log newer than the tarball.
set -uo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/smoke_test.sh <variant>}"
# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

DIST_DIR="${REPODIR}/dist/${GPU_TUNED_VARIANT}"
INFO="${DIST_DIR}/package-info.txt"
LOG="${DIST_DIR}/SMOKE_RESULTS_${GPU_TUNED_VARIANT}.log"
[[ -f "${INFO}" ]] || { echo "ERROR: ${INFO} not found. Run tuned/package.sh ${GPU_TUNED_VARIANT} first." >&2; exit 1; }
info() { sed -n "s/^$1=//p" "${INFO}"; }
TARBALL="${DIST_DIR}/$(info tarball)"; WANT_SHA="$(info sha256)"; RELEASE_TAG="$(info release_tag)"
BUILD_COMMIT="$(info build_commit)"
[[ -f "${TARBALL}" ]] || { echo "ERROR: ${TARBALL} not found." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
INSTALL_DIR="${WORK}/install"
ok() { echo "  ok:   $*"; }
fail() { echo "  FAIL: $*"; }

run() {
    echo "llama.cpp package smoke test -- variant=${GPU_TUNED_VARIANT} cuda=${CUDA_TAG}"
    echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "release: ${RELEASE_TAG}"
    echo "tarball: $(basename "${TARBALL}")"
    echo ""

    local got out rc ver lib rel
    got="$(sha256sum "${TARBALL}" | awk '{print $1}')"
    [[ "${got}" == "${WANT_SHA}" ]] && ok "sha256 matches package-info.txt (${got:0:12}...)" || fail "sha256 ${got} != package-info.txt ${WANT_SHA}"

    out="$(LLAMA_CPP_LOCAL_TARBALL="${TARBALL}" LLAMA_CPP_LOCAL_REPO="${REPODIR}" \
        LLAMA_CPP_VARIANT="${GPU_TUNED_VARIANT}" LLAMA_CPP_CUDA_VERSION="${CUDA_VER}" \
        bash "${REPODIR}/install.sh" --dir "${INSTALL_DIR}" 2>&1)"; rc=$?
    echo "${out}" | sed 's/^/        install.sh: /'
    if [[ ${rc} -eq 0 ]] && grep -q "Smoke test passed" <<< "${out}" && grep -q "Checksum verified" <<< "${out}"; then
        ok "install.sh from the local package: checksum verified, libraries resolve, a CUDA device is seen, a completion was served"
    else
        fail "install.sh exit ${rc} (see its output above)"; return
    fi

    ver="$(LD_LIBRARY_PATH="${INSTALL_DIR}" "${INSTALL_DIR}/llama-server-tuned" --version 2>&1 | grep -m1 '^version:' || true)"
    rel="$(LD_LIBRARY_PATH="${INSTALL_DIR}" "${INSTALL_DIR}/llama-server-tuned" --version 2>&1 | grep -m1 '^release:' || true)"
    [[ "${rel}" == "release: ${RELEASE_TAG}" ]] && ok "installed llama-server-tuned prints ${rel}" || fail "installed llama-server-tuned prints '${rel}', expected 'release: ${RELEASE_TAG}'"
    if [[ "${ver}" == *", commit ${BUILD_COMMIT})"* ]]; then
        ok "installed llama-server-tuned reports ${ver#version: }"
    else
        fail "installed llama-server-tuned reports '${ver}', expected commit ${BUILD_COMMIT}"
    fi

    # The build info: the stamp in the installed binary names this release and this commit, and the shipped
    # BUILD_INFO.json is that same stamp.
    if gpu_tuned_verify_build_info_json "${INSTALL_DIR}/llama-server-tuned" "release=${RELEASE_TAG}" "variant=${GPU_TUNED_VARIANT}" \
        "cuda.tag=${CUDA_TAG}" 2>&1 \
        && [[ "$(gpu_tuned_read_build_info "${INSTALL_DIR}/llama-server-tuned")" == "$(tr -d '\n' < "${INSTALL_DIR}/BUILD_INFO.json")" ]]; then
        ok "the installed stamp names ${RELEASE_TAG}, and BUILD_INFO.json is that same stamp"
    else
        fail "the installed build info does not name ${RELEASE_TAG}, or BUILD_INFO.json differs from the stamp"
    fi

    # NCCL: the stamp names where it came from, and the install matches: static means no libnccl.so anywhere.
    if [[ -n "${LLAMA_TUNED_NCCL_DIR}" ]]; then
        if gpu_tuned_verify_build_info_json "${INSTALL_DIR}/llama-server-tuned" "deps.nccl.tag=${LLAMA_TUNED_NCCL_TAG}" "deps.nccl.version=${LLAMA_TUNED_NCCL_VERSION}" deps.nccl.linkage=static 2>&1 \
            && [[ -z "$(find "${INSTALL_DIR}" -maxdepth 1 -name 'libnccl*' -print -quit)" ]] \
            && ! readelf -d "${INSTALL_DIR}"/libggml-cuda-tuned.so.0.* 2>/dev/null | grep -q 'Shared library: \[libnccl'; then
            ok "NCCL ${LLAMA_TUNED_NCCL_VERSION} from zbrad/nccl ${LLAMA_TUNED_NCCL_TAG}: stamped, linked statically, no libnccl.so installed or needed"
        else
            fail "NCCL: expected the stamp to name zbrad/nccl ${LLAMA_TUNED_NCCL_TAG} (static) and no libnccl.so in the install"
        fi
    elif gpu_tuned_verify_build_info_json "${INSTALL_DIR}/llama-server-tuned" "deps.nccl.version=${LLAMA_TUNED_NCCL_VERSION}" deps.nccl.linkage=shared 2>&1; then
        ok "NCCL ${LLAMA_TUNED_NCCL_VERSION} (system libnccl2, bundled) is stamped"
    else
        fail "NCCL: the stamp does not name system libnccl2 ${LLAMA_TUNED_NCCL_VERSION}"
    fi

    # The installed files are flat (INSTALL_DIR itself is the lib dir), so it goes on the path first.
    export GPU_TUNED_SMOKE_LD_EXTRA="${INSTALL_DIR}:${GPU_TUNED_TOOLKIT_LIB_DIR}"
    gpu_tuned_verify_resolves_in "${INSTALL_DIR}" "${INSTALL_DIR}/llama-server-tuned" \
        '^libllama-server-impl-tuned\.so' '^libllama-tuned\.so' '^libllama-common-tuned\.so' '^libggml-tuned\.so' '^libggml-cuda-tuned\.so' 2>&1 \
        && ok "libllama-server-impl, libllama, libllama-common, libggml, libggml-cuda (all -tuned) resolve inside the install directory" \
        || fail "libraries do not resolve inside the install directory"

    cmp -s "${INSTALL_DIR}/llmsrv.sh" "${REPODIR}/tuned/llmsrv.sh" && cmp -s "${INSTALL_DIR}/models/aliases.json" "${REPODIR}/models/aliases.json" \
        && ok "installed llmsrv.sh and models/aliases.json are this checkout's" || fail "installed llmsrv.sh or models/aliases.json differ from this checkout"
    echo "  complete: every check ran"
}

run 2>&1 | tee "${LOG}"
echo "" >> "${LOG}"
# A pass needs the positive evidence: run() reached its end ("complete:") and nothing failed. An abort inside
# run() (an unset variable) leaves no FAIL line, and must not read as a pass.
if grep -q '^  FAIL:' "${LOG}" || ! grep -q '^  complete: every check ran' "${LOG}"; then
    echo "=== Smoke test summary: FAILED ===" | tee -a "${LOG}"
    echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${LOG}"
    exit 1
fi
echo "=== Smoke test summary: passed ===" | tee -a "${LOG}"
echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${LOG}"
echo "Results written to ${LOG}"

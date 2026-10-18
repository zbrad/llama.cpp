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
# repos) -- its own build system derives the commit as `git rev-parse --short HEAD`
# (see cmake/build-info.cmake); this file derives it the same way so the packager can check that the
# binary was built from this source. The commit COUNT that `--version` also prints names nothing here
# (docs/ARCHITECTURE.md E6); the release identity is the date label.
#
#   CUDA_TAG=cu133 bash tuned/package.sh gb10     (or CUDA_VER=13.3)
#
# The toolkit comes from the vendored definitions in tuned/common-data/
# toolkits/<id>.env (zbrad/tuned-common), never from /usr/local/cuda or from
# whatever happens to be installed. There is no default: CUDA_TAG or CUDA_VER
# must name one. With neither set the loader fails and lists the defined toolkits
# (at a terminal it asks which to use, for that run only). Repo-specific settings live in tuned/repo.env, loaded last; it may
# not change any shared key (a conflict is a loud error).

GPU_TUNED_ARG_VARIANT="$1"
if [[ -z "${GPU_TUNED_ARG_VARIANT}" ]]; then
    echo "ERROR: env.sh requires a variant argument (gb10; rtx40/rtx50 not yet added)" >&2
    return 1 2>/dev/null || exit 1
fi

GPU_TUNED_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_TUNED_DATA_DIR="${GPU_TUNED_SELF_DIR}/common-data"
# shellcheck source=common-data/devices/gb10.conf
source "${GPU_TUNED_DATA_DIR}/devices/${GPU_TUNED_ARG_VARIANT}.conf" || return 1 2>/dev/null || exit 1
export GPU_TUNED_VARIANT GPU_TUNED_PLATFORM GPU_TUNED_CUDA_ARCH GPU_TUNED_HW_LABEL

# shellcheck source=common.sh
# Vendored from https://github.com/zbrad/tuned-common (pinned commit --
# see common.sh's own header/sync instructions to update). Provides
# gpu_tuned_installed_cuda_toolkits/verify_arch/verify_cuda_compat/
# embed_build_info/assert_platform, shared verbatim across the whole
# tuned-builds fleet instead of being hand-copied-and-edited per repo.
source "${GPU_TUNED_SELF_DIR}/common.sh" || return 1 2>/dev/null || exit 1

gpu_tuned_assert_platform "${GPU_TUNED_PLATFORM}" "${GPU_TUNED_VARIANT}" || return 1 2>/dev/null || exit 1

# --- Build commit: same derivation as cmake/build-info.cmake, so it matches what `llama-server --version`
#     reports; tuned/package.sh checks that. It is NOT the identity of a release: that is the UTC date
#     label (v0.<date>.<seq>-<variant>-<cuda>) package.sh allocates. ---
REPODIR="$(cd "${GPU_TUNED_SELF_DIR}/.." && pwd)"
# Respect a pre-set override (e.g. when re-packaging an already-built binary
# after a tooling-only commit that didn't require a rebuild -- the git-HEAD
# derivation below would otherwise mismatch what `llama-cli --version`
# actually reports for that binary).
: "${LLAMA_TUNED_BUILD_COMMIT:=$(git -C "${REPODIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
export LLAMA_TUNED_BUILD_COMMIT

# --- CUDA toolkit: named by CUDA_TAG (cu133) or CUDA_VER (13.3), never defaulted or guessed; loaded from
#     tuned/common-data/toolkits and verified (docs/ARCHITECTURE.md B4). Exports CUDA_VER, CUDA_TAG, CUDA_HOME
#     and puts $CUDA_HOME/bin on PATH. ---
gpu_tuned_select_toolkit "${GPU_TUNED_DATA_DIR}" "${GPU_TUNED_VARIANT}" || return 1 2>/dev/null || exit 1

# --- Repo-specific settings (CMake flags, ...), loaded last; may not change
#     any shared device/toolkit key. ---
gpu_tuned_load_repo_env "${GPU_TUNED_SELF_DIR}/repo.env" || return 1 2>/dev/null || exit 1

# --- Output layout: one tree per toolkit, tuned/build/<cuda-tag>/ (gitignored), with no variant level
#     (docs/ARCHITECTURE.md C2): cmake/ (the one fixed compile path, apart from build/, which the local
#     units run), dist/ (tarball, sidecar, package-info.txt), releases/ (generated test and smoke logs; the
#     tracked RELEASE_NOTES_*.md stay in tuned/releases/), ccache/, nccl/<tag>/. The claim refuses a tree
#     last used by another variant. LLAMA_TUNED_BUILD_DIR overrides the cmake tree (the cache check in
#     build.sh still applies). ---
GPU_TUNED_REPO_ROOT="${REPODIR}"
gpu_tuned_claim_toolkit_tree "${GPU_TUNED_REPO_ROOT}" "${CUDA_TAG}" "${GPU_TUNED_VARIANT}" || return 1 2>/dev/null || exit 1
LLAMA_TUNED_BUILD_ROOT="${GPU_TUNED_REPO_ROOT}/tuned/build/${CUDA_TAG}"
: "${LLAMA_TUNED_BUILD_DIR:=$(gpu_tuned_out_dir build "${GPU_TUNED_REPO_ROOT}" "${CUDA_TAG}" "${GPU_TUNED_VARIANT}")}" || return 1 2>/dev/null || exit 1
LLAMA_TUNED_DIST_DIR="$(gpu_tuned_out_dir dist "${GPU_TUNED_REPO_ROOT}" "${CUDA_TAG}" "${GPU_TUNED_VARIANT}")"
LLAMA_TUNED_RELEASES_DIR="$(gpu_tuned_out_dir releases "${GPU_TUNED_REPO_ROOT}" "${CUDA_TAG}" "${GPU_TUNED_VARIANT}")"
LLAMA_TUNED_TEST_LOG="${LLAMA_TUNED_RELEASES_DIR}/TEST_RESULTS_${GPU_TUNED_VARIANT}.log"
export LLAMA_TUNED_BUILD_DIR LLAMA_TUNED_DIST_DIR LLAMA_TUNED_RELEASES_DIR LLAMA_TUNED_TEST_LOG
export CCACHE_DIR="${LLAMA_TUNED_BUILD_ROOT}/ccache"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"

# --- NCCL: GGML_CUDA_NCCL=ON links NCCL, and the toolkit decides where it comes from. A toolkit with a line in
#     tuned/nccl.pins gets that zbrad/nccl release (built for exactly that toolkit), fetched, checksum-verified and
#     linked statically into libggml-cuda, so no libnccl.so is shipped or needed. Otherwise the toolkit file must pin
#     a system libnccl2 (TOOLKIT_NCCL_VERSION, checked by gpu_tuned_verify_toolkit) which package.sh bundles. A
#     toolkit that declares "none" and has no pin cannot be built: the host's libnccl2 was built for another CUDA. ---
LLAMA_TUNED_NCCL_DIR=""; LLAMA_TUNED_NCCL_TAG=""; LLAMA_TUNED_NCCL_VERSION=""
_nccl_tag="$(awk -v v="${GPU_TUNED_VARIANT}" -v c="${CUDA_TAG}" '$1 !~ /^#/ && $1==v && $2==c {print $3}' "${GPU_TUNED_SELF_DIR}/nccl.pins" 2>/dev/null)"
if [ -n "${_nccl_tag}" ]; then
    gpu_tuned_fetch_nccl_release "${_nccl_tag}" "${LLAMA_TUNED_BUILD_ROOT}/nccl/${_nccl_tag}" || { unset _nccl_tag; return 1 2>/dev/null || exit 1; }
    LLAMA_TUNED_NCCL_DIR="${LLAMA_TUNED_BUILD_ROOT}/nccl/${_nccl_tag}"
    LLAMA_TUNED_NCCL_TAG="${_nccl_tag}"
    LLAMA_TUNED_NCCL_VERSION="$(sed -n 's/^nccl_version=//p' "${LLAMA_TUNED_NCCL_DIR}/BUILD_INFO" | head -1)"
    [ -n "${LLAMA_TUNED_NCCL_VERSION}" ] || { echo "[tuned/env] ERROR: ${LLAMA_TUNED_NCCL_DIR}/BUILD_INFO has no nccl_version." >&2; unset _nccl_tag; return 1 2>/dev/null || exit 1; }
    echo "[tuned/env] NCCL ${LLAMA_TUNED_NCCL_VERSION} from zbrad/nccl ${_nccl_tag} (static, no libnccl.so shipped)" >&2
elif [ "${TOOLKIT_NCCL_VERSION:-none}" = none ]; then
    echo "[tuned/env] ERROR: ${CUDA_TAG} declares no system NCCL (TOOLKIT_NCCL_VERSION=none) and tuned/nccl.pins has no line for ${GPU_TUNED_VARIANT} ${CUDA_TAG}." >&2
    echo "  Pin a zbrad/nccl release built for it in tuned/nccl.pins, or choose a toolkit with a system NCCL pin." >&2
    unset _nccl_tag; return 1 2>/dev/null || exit 1
else
    LLAMA_TUNED_NCCL_VERSION="${TOOLKIT_NCCL_VERSION}"
fi
unset _nccl_tag
export LLAMA_TUNED_NCCL_DIR LLAMA_TUNED_NCCL_TAG LLAMA_TUNED_NCCL_VERSION

# gpu_tuned_verify_arch/gpu_tuned_verify_cuda_compat now come from
# common.sh (sourced above); call sites in package.sh pass
# GPU_TUNED_CUDA_ARCH explicitly (the shared version takes it as an arg
# instead of reading a global, since different repos in the fleet name
# their arch var differently).

# Upstream this fork tracks, for the build-info stamp's upstream.base / nearest_tag. Declared, never guessed.
: "${GPU_TUNED_UPSTREAM_REF:=upstream/master}"
export GPU_TUNED_UPSTREAM_REF

# embed_build_info <staged-elf> <component> <release-tag> <ui-name> <ui-sha256> — stamps the JSON build info
# (tuned-common, docs/ARCHITECTURE.md "Build info") into <staged-elf>'s .tuned_build_info section; read it with
#   gpu_tuned_read_build_info <elf> | jq .
# The release tag is the identity. upstream.declared_version is what the built llama-server reports as its
# version ("0.5.0-dev"), fork.commit_count the repo-relative count llama.cpp's own --version calls "build".
# Git fields (fork, upstream) are added automatically from the checkout the packager runs in.
embed_build_info() {
    local target="$1" component="$2" release="$3" ui_name="$4" ui_sha="$5" declared nvcc_full
    declared="$(LD_LIBRARY_PATH="${LLAMA_TUNED_BUILD_DIR}/bin" "${LLAMA_TUNED_BUILD_DIR}/bin/llama-server" --version 2>&1 | sed -n 's/^version: \([^ ]*\) (build.*/\1/p' | head -1)"
    [[ -n "${declared}" ]] || { echo "ERROR: embed_build_info: could not read the version from ${LLAMA_TUNED_BUILD_DIR}/bin/llama-server --version." >&2; return 1; }
    local nccl_fields=()
    if [ -n "${LLAMA_TUNED_NCCL_DIR}" ]; then
        nccl_fields=("deps.nccl.source=zbrad/nccl" "deps.nccl.tag=${LLAMA_TUNED_NCCL_TAG}" "deps.nccl.version=${LLAMA_TUNED_NCCL_VERSION}" "deps.nccl.linkage=static")
    else
        nccl_fields=("deps.nccl.source=system libnccl2" "deps.nccl.version=${LLAMA_TUNED_NCCL_VERSION}" "deps.nccl.linkage=shared")
    fi
    nvcc_full="$("${CUDA_HOME}/bin/nvcc" --version | sed -n 's/.*release [0-9.]*, V\([0-9.]*\).*/\1/p' | head -1)"
    gpu_tuned_embed_build_info_json "${target}" \
        package=llama.cpp "component=${component}" "release=${release}" "variant=${GPU_TUNED_VARIANT}" \
        "hardware=${GPU_TUNED_HW_LABEL}" "arch=sm_${GPU_TUNED_CUDA_ARCH}" \
        "cuda.tag=${CUDA_TAG}" "cuda.version=${CUDA_VER}" "cuda.nvcc=${nvcc_full:-unknown}" \
        "upstream.declared_version=${declared}" \
        "deps.ui.name=${ui_name}" "deps.ui.tarball_sha256=${ui_sha}" \
        "${nccl_fields[@]}"
}

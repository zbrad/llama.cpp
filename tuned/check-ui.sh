#!/bin/bash
# tuned/check-ui.sh <build-dir> — refuse unless the web UI embedded in <build-dir>'s llama-server
# is the one built by the llama-ui-tuned repo (patched dependency set, audited), and that UI
# was built from the same tools/ui sources this checkout has.
#
# Why: upstream's CMake falls back to `npm ci` of upstream's lockfile, or to a download, when
# tools/ui/dist is absent. Either would ship an unaudited bundle without any visible sign.
#
# Two checks:
#   1. Content: every asset the build embedded (build-dir/tools/ui/ui-gzip/_gzip/*.gz, the files
#      ui.cpp is generated from) is byte-identical to the same path in the llama-ui-tuned
#      tarball's ui/ tree, and the file sets are equal.
#   2. Skew: the tarball's BUILD_INFO source_commit has the same tools/ui tree as HEAD. Compared
#      by tree, not by commit: unrelated llama.cpp commits do not make the UI stale.
#
# The tarball is $LLAMA_UI_TARBALL, else the newest dist/llama-ui-tuned-*.tar.gz in
# $LLAMA_UI_REPO (default ~/gh/llama-ui-tuned); its .sha256 file must verify.
# On success the last stdout line is "<ui name> <tarball sha256>".
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:?usage: tuned/check-ui.sh <build-dir>}"
GZ_DIR="${BUILD_DIR}/tools/ui/ui-gzip/_gzip"
fail() { echo "ERROR (check-ui): $*" >&2; exit 1; }

[[ -d "${GZ_DIR}" ]] || fail "${GZ_DIR} not found: this build embedded no gzipped UI assets (needs LLAMA_UI_GZIP=ON and a dist from llama-ui-tuned)."

TARBALL="${LLAMA_UI_TARBALL:-}"
if [[ -z "${TARBALL}" ]]; then
    UI_REPO="${LLAMA_UI_REPO:-${HOME}/gh/llama-ui-tuned}"
    TARBALL="$(find "${UI_REPO}/dist" -maxdepth 1 -name 'llama-ui-tuned-*.tar.gz' -print 2>/dev/null | sort | tail -1)"
fi
[[ -f "${TARBALL}" ]] || fail "no llama-ui-tuned tarball found (set LLAMA_UI_TARBALL)."
[[ -f "${TARBALL}.sha256" ]] || fail "${TARBALL}.sha256 not found."
(cd "$(dirname "${TARBALL}")" && sha256sum -c --quiet "$(basename "${TARBALL}").sha256") || fail "${TARBALL} does not match its .sha256."

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
tar -xzf "${TARBALL}" -C "${WORK}" --strip-components=1
[[ -d "${WORK}/ui" && -f "${WORK}/BUILD_INFO" ]] || fail "${TARBALL} has no ui/ tree or BUILD_INFO."

# 1. content
(cd "${WORK}/ui" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "${WORK}/want.txt"
(cd "${GZ_DIR}" && find . -type f -print0 | sort -z | while IFS= read -r -d '' f; do
    printf '%s  %s\n' "$(gzip -dc "${f}" | sha256sum | cut -d' ' -f1)" "${f}"
done) > "${WORK}/have.txt"
if ! diff -u "${WORK}/want.txt" "${WORK}/have.txt" > "${WORK}/diff.txt"; then
    head -20 "${WORK}/diff.txt" >&2
    fail "the UI embedded in ${BUILD_DIR} is not the llama-ui-tuned build $(basename "${TARBALL}")."
fi

# 2. skew
SRC_COMMIT="$(sed -n 's/^source_commit=//p' "${WORK}/BUILD_INFO")"
[[ -n "${SRC_COMMIT}" ]] || fail "BUILD_INFO has no source_commit."
UI_TREE="$(git -C "${REPODIR}" rev-parse "${SRC_COMMIT}:tools/ui" 2>/dev/null)" || fail "source commit ${SRC_COMMIT} not in this checkout; fetch it, or rebuild the UI from this checkout (tuned/sync-upstream.sh in llama-ui-tuned)."
HEAD_TREE="$(git -C "${REPODIR}" rev-parse HEAD:tools/ui)"
[[ "${UI_TREE}" == "${HEAD_TREE}" ]] || fail "tools/ui differs between the UI's source ${SRC_COMMIT:0:9} and HEAD; rebuild the UI (re-run tuned/sync-upstream.sh in llama-ui-tuned)."

echo "UI ok: $(sed -n 's/^name=//p' "${WORK}/BUILD_INFO"), $(wc -l < "${WORK}/want.txt") assets identical, tools/ui tree ${HEAD_TREE:0:9} == source ${SRC_COMMIT:0:9}" >&2
echo "$(sed -n 's/^name=//p' "${WORK}/BUILD_INFO") $(sha256sum "${TARBALL}" | cut -d' ' -f1)"

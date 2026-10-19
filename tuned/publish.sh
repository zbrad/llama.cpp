#!/bin/bash
# tuned/publish.sh <variant> — publishes the GitHub release that tuned/release.sh <variant> gated, and nothing else.
# It publishes only what release.sh's gates saw: it reads the ready-marker RELEASE_READY_<variant> and refuses
# unless HEAD, the release notes and every asset are unchanged since release.sh passed (gpu_tuned_publish_ready).
# After publishing it renames the marker spent, so one passing release.sh run publishes once. With no marker it
# does nothing: run tuned/release.sh <variant> first.
#
#   CUDA_TAG=cu134 bash tuned/release.sh gb10      # gates; writes the marker
#   CUDA_TAG=cu134 bash tuned/publish.sh gb10      # publishes
set -uo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${1:?usage: tuned/publish.sh <variant>}"

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${VARIANT}" || exit 1
cd "${REPODIR}"

READY_MARKER="${LLAMA_TUNED_RELEASES_DIR}/RELEASE_READY_${GPU_TUNED_VARIANT}"

gpu_tuned_publish_ready "${READY_MARKER}" || exit 1
echo ""
echo "Done: https://github.com/zbrad/llama.cpp/releases/tag/$(sed -n 's/^tag=//p' "${READY_MARKER}.published")"

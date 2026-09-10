#!/bin/bash
# tuned/install-llmsrv.sh — copy llmsrv.sh + its alias table + only the
# chat templates it actually references into a self-contained support
# directory, so llmsrv.sh keeps working after this checkout is gone.
#
# Why: tuned/package.sh's release tarball ships llama-server + shared
# libs only (for Ollama consumption) -- no llmsrv.sh, no
# models/aliases.json, no models/templates/*.jinja. A machine set up
# purely from that tarball has no alias table at all. Run this once (from
# any machine with a full checkout -- doesn't have to be the target
# machine, just copy the result over) to fix that.
#
# Usage: bash tuned/install-llmsrv.sh
#
# Installs to $XDG_DATA_HOME/llmsrv (default ~/.local/share/llmsrv),
# mirroring the checkout's own models/... layout so llmsrv.sh's path
# resolution works unmodified in either mode -- see its own REPODIR/
# DATA_DIR comment. Symlinks the installed copy at ~/.local/bin/llmsrv.sh
# (not the checkout copy), so the checkout can be deleted afterward.
#
# Re-run after any local change to models/aliases.json or the templates
# it references to refresh the installed copy.
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/llmsrv"
BIN_DIR="${HOME}/.local/bin"

[[ -f "${REPODIR}/models/aliases.json" ]] || {
    echo "error: ${REPODIR}/models/aliases.json not found -- run this from a full checkout" >&2
    exit 1
}

mkdir -p "${RESOURCE_DIR}/models/templates" "${BIN_DIR}"
cp -p "${REPODIR}/tuned/llmsrv.sh" "${RESOURCE_DIR}/llmsrv.sh"
cp -p "${REPODIR}/models/aliases.json" "${RESOURCE_DIR}/models/aliases.json"

# Only the templates actually referenced -- models/templates/ has 70+
# entries for models this deployment doesn't necessarily run.
templates="$(jq -r '.models[].chat_template_file // empty' "${REPODIR}/models/aliases.json" | sort -u)"
copied=0
while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    src="${REPODIR}/${rel}"
    if [[ ! -f "$src" ]]; then
        echo "warning: ${rel} referenced in aliases.json but not found, skipping" >&2
        continue
    fi
    cp -p "$src" "${RESOURCE_DIR}/${rel}"
    copied=$((copied + 1))
done <<<"$templates"

ln -sf "${RESOURCE_DIR}/llmsrv.sh" "${BIN_DIR}/llmsrv.sh"

echo "Installed to ${RESOURCE_DIR} (aliases.json + ${copied} referenced template(s))"
echo "Symlinked: ${BIN_DIR}/llmsrv.sh -> ${RESOURCE_DIR}/llmsrv.sh"
echo "This checkout is no longer required for llmsrv.sh to run."

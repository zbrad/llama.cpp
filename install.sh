#!/usr/bin/env bash
# install.sh -- one-shot setup for tuned/llmsrv.sh on a machine with no git
# checkout of this repo: fetches the matching zbrad/llama.cpp GPU release
# (llama-server + llama-quantize + libs, checksum-verified), models/aliases.json,
# the chat templates it references, and llmsrv.sh itself, all into one
# directory.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuning-v28/install.sh | bash
#   # a specific directory (current folder, or anywhere else):
#   curl -fsSL .../install.sh | bash -s -- --dir .
#   # or, from a checkout:
#   bash install.sh [--dir <path>]
#
# This script itself, models/aliases.json, and llmsrv.sh are all fetched
# from the same pinned "tuning-vN" tag (REPO_REF below) -- a lightweight
# tag bumped only when this tooling actually changes (commits ahead of
# upstream/master that touch tuned/, models/aliases.json, or install.sh
# itself), not on every unrelated upstream sync tuned-builds also carries.
# Pin an exact tag/commit yourself via REPO_REF if you need full
# reproducibility beyond the default. The GPU binary release is a
# completely separate axis -- always resolved fresh via the GitHub API by
# variant+CUDA (or pinned via LLAMA_CPP_TAG), independent of REPO_REF.
#
# Default install dir is $XDG_DATA_HOME/llmsrv (usually
# ~/.local/share/llmsrv) -- this matches llmsrv.sh's own hardcoded
# fallback, so the default install needs no extra env var: llmsrv.sh
# (symlinked onto ~/.local/bin) just works. Installing to any other --dir
# needs LLMSRV_HOME=<dir> set when running the installed llmsrv.sh --
# there's no fixed path to autodetect a custom location from, and this
# script tells you the exact command to use at the end.
#
# Self-contained (curl-pipeable) -- doesn't source anything else, and
# doesn't require a local git checkout (fetches models/aliases.json and
# its templates from GitHub directly via raw.githubusercontent.com).
#
# Env overrides:
#   INSTALL_DIR                same as --dir
#   LLAMA_CPP_VARIANT/LLAMA_CPP_CUDA_VERSION/LLAMA_CPP_TAG  (GPU release matching)
#   REPO_REF                    tag/commit to fetch aliases.json/llmsrv.sh/
#                                this script's own updates from (default: see below)
set -euo pipefail

REPO="zbrad/llama.cpp"
REPO_REF="${REPO_REF:-tuning-v28}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REPO_REF}"

DEFAULT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/llmsrv"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"
IS_DEFAULT_DIR=true
VARIANT="${LLAMA_CPP_VARIANT:-}"
CUDA_VERSION="${LLAMA_CPP_CUDA_VERSION:-}"
EXACT_TAG="${LLAMA_CPP_TAG:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)     INSTALL_DIR="$2"; IS_DEFAULT_DIR=false; shift 2 ;;
        --dir=*)   INSTALL_DIR="${1#--dir=}"; IS_DEFAULT_DIR=false; shift ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

status() { echo ">>> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required but not found"
command -v tar >/dev/null 2>&1 || die "tar is required but not found"

mkdir -p "${INSTALL_DIR}"
INSTALL_DIR="$(cd "${INSTALL_DIR}" && pwd)"  # absolute, symlinks resolved

# --- Detect GPU variant ---
if [ -z "$VARIANT" ]; then
    command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found; pass LLAMA_CPP_VARIANT=gb10|rtx40|rtx50 explicitly"
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
    case "$gpu_name" in
        *GB10*)   VARIANT="gb10" ;;
        *RTX*40*) VARIANT="rtx40" ;;
        *RTX*50*) VARIANT="rtx50" ;;
        *) die "could not auto-detect GPU variant from nvidia-smi output ('$gpu_name'); pass LLAMA_CPP_VARIANT explicitly" ;;
    esac
fi

# --- Verify CPU architecture matches the variant ---
machine_arch="$(uname -m)"
case "$VARIANT" in
    gb10)        expected_arch="aarch64" ;;
    rtx40|rtx50) expected_arch="x86_64" ;;
    *)           expected_arch="" ;;
esac
if [ -n "$expected_arch" ] && [ "$machine_arch" != "$expected_arch" ]; then
    die "architecture mismatch: this machine is $machine_arch, but variant '$VARIANT' releases are built for $expected_arch (set LLAMA_CPP_VARIANT explicitly if auto-detection got this wrong)"
fi

# --- Detect CUDA toolkit version ---
if [ -z "$CUDA_VERSION" ]; then
    if command -v nvcc >/dev/null 2>&1; then
        CUDA_VERSION="$(nvcc --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')"
    fi
    if [ -z "$CUDA_VERSION" ]; then
        CUDA_VERSION="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9]+\.[0-9]+' | awk '{print $3}')"
    fi
    [ -n "$CUDA_VERSION" ] || die "could not auto-detect CUDA version; pass LLAMA_CPP_CUDA_VERSION explicitly"
fi
CUDA_TAG="cu${CUDA_VERSION//./}"
CUDA_MAJOR="${CUDA_VERSION%%.*}"

status "Install dir:  $INSTALL_DIR"
status "Variant:      $VARIANT"
status "CUDA version: $CUDA_VERSION ($CUDA_TAG)"

# --- Resolve release tag: exact CUDA match preferred, else newest release
# sharing the same CUDA major -- CUDA's own minor version compatibility
# guarantees a binary built with toolkit X.y runs on any driver reporting
# CUDA X.0 or newer, regardless of how the release's minor compares to
# the host's reported minor (confirmed live: node-2's driver reports
# "CUDA Version: 13.0" yet already runs cu133 releases fine -- an
# X.y-must-be-<=-host-minor gate here would wrongly reject that) ---
if [ -z "$EXACT_TAG" ]; then
    candidates="$(
        curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=100" \
            | grep -o '"tag_name": *"[^"]*"' \
            | sed 's/.*"tag_name": *"\([^"]*\)"/\1/' \
            | grep -E "^v[0-9]+-${VARIANT}-cu[0-9]+\$" || true
    )"
    [ -n "$candidates" ] || die "no releases found on $REPO matching variant '$VARIANT'"

    TAG="$(echo "$candidates" | grep -- "-${CUDA_TAG}\$" | sort -t- -k1.2 -n | tail -1 || true)"
    if [ -z "$TAG" ]; then
        TAG="$(
            echo "$candidates" | while read -r t; do
                t_cuda="${t##*-cu}"
                t_major="${t_cuda:0:2}"
                [ "$t_major" = "$CUDA_MAJOR" ] && echo "$t"
            done | sort -t- -k1.2 -n | tail -1
        )"
        [ -n "$TAG" ] && status "NOTE: no exact CUDA ${CUDA_VERSION} release for ${VARIANT}; falling back to $TAG (same CUDA major, minor-version compatible)"
    fi
    [ -n "$TAG" ] || die "no release found matching variant '$VARIANT' and CUDA major ${CUDA_MAJOR}.x"
else
    TAG="$EXACT_TAG"
fi
status "Release: $TAG"

asset_name="$(
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" \
        | grep -o '"name": *"[^"]*\.tar\.gz"' | sed 's/.*"name": *"\([^"]*\)"/\1/' | head -1 || true
)"
[ -n "$asset_name" ] || die "no .tar.gz asset found in release $TAG"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

sha_name="${asset_name}.sha256"
have_sha=false
if curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${sha_name}" -o "$WORK_DIR/release.tar.gz.sha256" 2>/dev/null; then
    have_sha=true
else
    status "WARNING: no checksum (${sha_name}) published for this release -- skipping integrity verification"
fi

status "Downloading $asset_name..."
curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${asset_name}" -o "$WORK_DIR/release.tar.gz"

if $have_sha; then
    expected="$(awk '{print $1}' "$WORK_DIR/release.tar.gz.sha256")"
    actual="$(sha256sum "$WORK_DIR/release.tar.gz" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || die "checksum mismatch for ${asset_name}: expected ${expected}, got ${actual} -- download may be corrupted, try again"
    status "Checksum verified ($actual)"
fi

# Flat layout: llama-server/llama-quantize + every lib land directly in
# INSTALL_DIR (RPATH in the release is $ORIGIN -- resolved from the
# binary's own canonical directory even when invoked through a symlink --
# so there's no need to split binaries and libs into separate dirs).
tar -xzf "$WORK_DIR/release.tar.gz" -C "$INSTALL_DIR"
[ -x "$INSTALL_DIR/llama-server" ] || die "llama-server not found after extracting $TAG"

# --- Fetch models/aliases.json + only the templates it references ---
status "Fetching models/aliases.json..."
mkdir -p "$INSTALL_DIR/models/templates"
curl -fsSL "${RAW_BASE}/models/aliases.json" -o "$INSTALL_DIR/models/aliases.json"

templates="$(grep -oE '"chat_template_file": *"[^"]*"' "$INSTALL_DIR/models/aliases.json" \
    | sed -E 's/.*"([^"]+)"$/\1/' | sort -u)"
copied=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$(dirname "$INSTALL_DIR/$rel")"
    if curl -fsSL "${RAW_BASE}/${rel}" -o "$INSTALL_DIR/${rel}"; then
        copied=$((copied + 1))
    else
        echo "warning: failed to fetch ${rel}, skipping" >&2
    fi
done <<<"$templates"
status "aliases.json + ${copied} referenced template(s) fetched"

# --- Fetch llmsrv.sh itself ---
status "Fetching llmsrv.sh..."
curl -fsSL "${RAW_BASE}/tuned/llmsrv.sh" -o "$INSTALL_DIR/llmsrv.sh"
chmod +x "$INSTALL_DIR/llmsrv.sh"

echo ""
status "Installed to ${INSTALL_DIR}"
if $IS_DEFAULT_DIR; then
    BIN_DIR="${HOME}/.local/bin"
    mkdir -p "$BIN_DIR"
    ln -sf "$INSTALL_DIR/llmsrv.sh" "$BIN_DIR/llmsrv.sh"
    ln -sf "$INSTALL_DIR/llama-server" "$BIN_DIR/llama-server"
    ln -sf "$INSTALL_DIR/llama-quantize" "$BIN_DIR/llama-quantize"
    status "Symlinked onto ${BIN_DIR} (make sure it's on PATH)"
    echo ""
    echo "Run it:"
    echo "  llmsrv.sh --model <name> start"
else
    echo ""
    echo "This isn't the default location, so llmsrv.sh needs to be told"
    echo "where to find its resources explicitly:"
    echo "  LLMSRV_HOME=${INSTALL_DIR} ${INSTALL_DIR}/llmsrv.sh --model <name> start"
fi

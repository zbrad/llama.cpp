#!/usr/bin/env bash
# ~/llmsrv.sh — launch a GGUF model via bare llama-server as a
# systemd --user service (no sudo needed for start/stop/restart). See
# docs/gb10/llmsrv-launcher.md for the full writeup of this script's
# design (usage, env overrides, the memory-safety mechanisms below, and
# why --n-gpu-layers is fixed at 99). Fixes applied here:
#
#   - --chat-template-file (super only): that GGUF has no embedded
#     tokenizer.chat_template (it's the Ollama-blob-sourced copy). Without
#     an explicit template, llama-server's --jinja silently falls back to a
#     bare ChatML stub with no system-role/tool-call/reasoning support. The
#     real template was extracted from a sibling copy of the model
#     (models/nemotron-120b/Nemotron-3-Super-120B-Q4_K.gguf in the
#     llama.cpp checkout) and saved into llama.cpp's own models/templates/.
#     nano's GGUF carries its own embedded template already -- no override
#     needed there.
#   - --load-mode none: replaces the deprecated --no-mmap. GB10's cold-mmap
#     load path is ~259 MB/s (synchronous cudaMemcpyAsync per tensor);
#     direct read hits ~1131 MB/s.
#   - --reasoning-preserve: the extracted template supports it
#     (chat_template_caps.supports_preserve_reasoning), and llama-server's
#     own startup log recommends turning it on.
#   - No --special: it forces ALL special/control tokens into
#     message.content, including the EOS token itself — was leaking a
#     literal "<|im_end|>" onto the end of every response. Reasoning-tag
#     extraction into message.reasoning_content works fine without it
#     (that's --reasoning-format auto's job, unrelated to --special).
#   - --temp 1.0 (not 0.6): NVIDIA's own NIM reference doc gives
#     temp=1.0/top_p=0.95 for reasoning/chat across all serving backends.
#     0.6 traced to a misreading of Unsloth's guide, which gives that
#     value for tool-calling specifically, not general chat.
#   - --ctx-size is capped to the model's own trained context length (read
#     from the GGUF header via gguf-py) instead of always requesting
#     LLMSRV_CTX_SIZE, and check_mem's pre-flight now sizes the KV cache
#     from that same metadata instead of a flat weights-only estimate. Plus
#     a post-start guard (wait_for_healthy_or_die) that stops the unit
#     itself if MemAvailable collapses before it comes up healthy. All
#     added after the 2026-09-06 node-1 incident: a forced --ctx-size
#     262144 on a 40960-trained-context model, while ComfyUI was already
#     GPU-resident, overcommitted GB10's shared unified memory and wedged a
#     driver-level lock (nvidia-smi included) for 16+ minutes with nothing
#     watching to kill it, hard-locking the box for ~19h45m with no
#     OOM-killer and no hardware watchdog to recover it. See
#     docs/gb10/llmsrv-launcher.md's "Memory safety on unified memory"
#     section for the full incident writeup.
#
# Usage: ~/llmsrv.sh [--model <name-from-models/aliases.json>|<path>] [start|stop|status|restart]
#   (--model defaults to 'super'; command defaults to 'start')
#   Known model names, their filenames, aliases, and chat templates come
#   from models/aliases.json in the llama.cpp checkout -- see that file's
#   own comment for the search-path resolution it uses.
#   Env overrides: LLMSRV_HOST, LLMSRV_CTX_SIZE (ceiling only now -- still
#   clamped down to the model's trained context if that's smaller),
#   LLMSRV_MEM_MARGIN_GIB, LLMSRV_PRIMARY_HOST, LLMSRV_PORT,
#   LLMSRV_START_TIMEOUT_SEC (how long to wait for /health before giving
#   up), LLMSRV_CRITICAL_MEM_GIB (abort threshold for MemAvailable during
#   startup).
#
# Process management: generates and drives a systemd --user unit
# (llmsrv-<alias>.service) rather than a bare nohup'd background process --
# matches how node-2 runs nano, and needs no sudo for restart/stop.
# Note: --user services stop when your login session ends unless linger is
# enabled for this account (`loginctl show-user $USER -p Linger`); this
# script doesn't attempt to enable it (that's a separate, one-time,
# possibly-privileged step).
set -euo pipefail

REPODIR="/home/zbrad/gh/llama.cpp"
LLAMA_SERVER="${REPODIR}/build/bin/llama-server"
ALIASES_FILE="${REPODIR}/models/aliases.json"
UNIT_DIR="${HOME}/.config/systemd/user"
HOST="${LLMSRV_HOST:-0.0.0.0}"
CTX_SIZE="${LLMSRV_CTX_SIZE:-262144}"
MEM_MARGIN_GIB="${LLMSRV_MEM_MARGIN_GIB:-8}"  # runtime overhead beyond weights+KV (activations, CUDA context, output buffers) -- KV cache itself is now sized explicitly in check_mem, not folded into this margin
PRIMARY_HOST="${LLMSRV_PRIMARY_HOST:-node-2}"  # host consumers (e.g. Open WebUI) run on; anywhere else is "remote"
START_TIMEOUT_SEC="${LLMSRV_START_TIMEOUT_SEC:-300}"  # max time to wait for /health before stopping the unit and giving up
CRITICAL_MEM_GIB="${LLMSRV_CRITICAL_MEM_GIB:-2}"  # MemAvailable floor during startup; cross it and we stop the unit rather than let the driver wedge

die() { echo "error: $*" >&2; exit 1; }

# gguf_meta MODEL_PATH -- print shell-evalable KV metadata (ARCH,
# BLOCK_COUNT, CONTEXT_LENGTH, HEAD_COUNT_KV, KEY_LENGTH, VALUE_LENGTH) read
# straight from the GGUF header via gguf-py (vendored in this repo at
# gguf-py/) -- no model load, just the header. Empty output / non-zero exit
# means introspection failed (no python3, no gguf-py, or an architecture
# gguf-py doesn't recognize) -- callers must treat every field as unknown,
# not 0, and fall back to the pre-existing (weights-only) behavior rather
# than guessing.
gguf_meta() {
    command -v python3 >/dev/null 2>&1 || return 1
    PYTHONPATH="${REPODIR}/gguf-py" python3 - "$1" 2>/dev/null <<'PYEOF'
import sys
import gguf

try:
    r = gguf.GGUFReader(sys.argv[1])
except Exception:
    sys.exit(1)

def scalar(key):
    field = r.fields.get(key)
    if field is None:
        return None
    if field.types[-1] == gguf.GGUFValueType.STRING:
        return bytes(field.parts[-1]).decode("utf-8", "replace")
    return field.parts[field.data[0]][0]

arch = scalar("general.architecture")
if not arch:
    sys.exit(1)

print(f"ARCH={arch}")
for key in ("block_count", "context_length", "attention.head_count_kv",
            "attention.key_length", "attention.value_length"):
    val = scalar(f"{arch}.{key}")
    if val is not None:
        print(f"{key.rsplit('.', 1)[-1].upper()}={int(val)}")
PYEOF
}

# kv_type_bytes CACHE_TYPE -- approx bytes/element for a llama.cpp
# --cache-type-k/v value, always rounded UP (this feeds a safety check, so
# overestimating is the safe direction). Exact for f32/f16; quantized types
# (q8_0, q5_0, etc.) are real fractional-byte values well below this, so
# treating them as f16-equivalent is a deliberate, conservative simplification.
kv_type_bytes() {
    case "$1" in
        f32) echo 4 ;;
        *)   echo 2 ;;
    esac
}

# --- argument parsing: pull --model out of the args, leaving the command ---
MODEL_CHOICE="super"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)     MODEL_CHOICE="${2:-}"; shift 2 ;;
        --model=*)   MODEL_CHOICE="${1#--model=}"; shift ;;
        *)           ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"

# --- resolve MODEL_CHOICE (a known name from models/aliases.json, or an
# absolute path) into MODEL/CHAT_TEMPLATE/MODEL_LABEL/MODEL_ALIAS ---
# The alias table maps a short name to a bare filename + alias + optional
# chat template, not a machine-specific absolute path -- the filename is
# resolved by walking aliases.json's search_paths (in order) so the same
# table works unmodified on this machine, node-2, or anywhere else the
# GGUFs happen to live under one of those roots. llama-server's own
# --models-preset/router mechanism is INI-only (docs/preset.md); this table
# is JSON, read by this script only, not by llama-server itself.
case "$MODEL_CHOICE" in
    /*)
        MODEL="$MODEL_CHOICE"
        CHAT_TEMPLATE=""
        MODEL_LABEL="$(basename "$MODEL_CHOICE")"
        MODEL_ALIAS="$MODEL_LABEL"
        DEFAULT_PORT=8091
        ;;
    *)
        [[ -f "$ALIASES_FILE" ]] || die "alias table not found at $ALIASES_FILE"
        entry="$(jq -c --arg name "$MODEL_CHOICE" '.models[$name] // empty' "$ALIASES_FILE")"
        [[ -n "$entry" ]] || die "unknown --model '$MODEL_CHOICE' -- expected a name from $ALIASES_FILE (models[]) or an absolute path"

        filename="$(jq -r '.filename' <<<"$entry")"
        MODEL_ALIAS="$(jq -r '.alias' <<<"$entry")"
        MODEL_LABEL="$MODEL_ALIAS"
        chat_template_rel="$(jq -r '.chat_template_file // empty' <<<"$entry")"
        CHAT_TEMPLATE=""
        [[ -n "$chat_template_rel" ]] && CHAT_TEMPLATE="${REPODIR}/${chat_template_rel}"
        DEFAULT_PORT="$(jq -r '.port // 8091' <<<"$entry")"

        MODEL=""
        tried=()
        while IFS= read -r dir; do
            dir="${dir/#\~/$HOME}"
            tried+=("${dir}/${filename}")
            if [[ -f "${dir}/${filename}" ]]; then
                MODEL="${dir}/${filename}"
                break
            fi
        done < <(jq -r '.search_paths[]' "$ALIASES_FILE")

        [[ -n "$MODEL" ]] || die "'$filename' (model '$MODEL_CHOICE') not found in any search_paths entry -- tried: ${tried[*]}"
        ;;
esac

# resolve_launch_config -- everything here is only needed to actually start
# the server (check_mem/write_unit), not for status/stop, so it's a function
# called explicitly from do_start rather than unconditional top-level code:
# avoids a GGUF read (and its capping-message output) on every invocation.
resolve_launch_config() {
    # --n-gpu-layers 99 (in ExecStart below) is a fixed "offload every
    # layer" idiom, not a literal layer count -- llama-server clamps it to
    # the model's real block_count internally, and every model in
    # aliases.json has well under 99 layers (36-88, confirmed via GGUF
    # headers 2026-09-08). It's fixed rather than scaled to model size
    # because GB10's Grace-Blackwell chip-to-chip memory is one coherent
    # ~121GiB pool, not a small discrete VRAM tier backed by a larger/
    # slower system-RAM tier -- there's no separate VRAM ceiling to trade
    # against, so forcing all layers onto GPU costs nothing memory-wise
    # here (check_mem's required_gib doesn't vary with --n-gpu-layers
    # either, for the same reason -- see its own comments).
    #
    # That assumption is FALSE on a genuine discrete-GPU box: forcing every
    # layer onto a much smaller VRAM pool can OOM/crash the GPU instead of
    # just degrading to slower CPU execution, and check_mem wouldn't catch
    # it either (it only ever checks system MemAvailable, never VRAM). Warn
    # loudly rather than silently misbehave if this doesn't look like GB10
    # -- nvidia-smi reports memory.total as literal "N/A" there; a real
    # number means a distinct, bounded VRAM pool exists.
    local gpu_mem_total_mib
    gpu_mem_total_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
    if [[ "$gpu_mem_total_mib" =~ ^[0-9]+$ ]]; then
        cat >&2 <<WARN
!!! llmsrv.sh: WARNING -- nvidia-smi reports a real VRAM size (${gpu_mem_total_mib}MiB),
!!! not the unified-memory "N/A" this script assumes (GB10 only). This script
!!! hardcodes --n-gpu-layers 99 and sizes memory via check_mem's system-RAM-only
!!! estimate on the assumption there's no separate VRAM ceiling -- both are
!!! WRONG on real discrete-GPU hardware. --n-gpu-layers 99 will try to force
!!! every layer onto this GPU regardless of its actual VRAM size and can
!!! OOM/crash rather than degrade gracefully. Lower --n-gpu-layers to fit this
!!! GPU's real VRAM before trusting this script here.
WARN
    fi

    # Cache types for the KV cache -- affects both memory sizing (check_mem)
    # and the ExecStart args (write_unit), so computed once here rather than
    # duplicated in both places. f16 (llama.cpp's default) unless overridden;
    # 'super' uses a quantized KV cache to fit its ~1M-token trained context
    # (see models/aliases.json / gguf_meta's CONTEXT_LENGTH for that model --
    # it's real, not a mistake, unlike qwen3-4b's).
    CACHE_TYPE_K="f16"
    CACHE_TYPE_V="f16"
    EXTRA_LLAMA_ARGS=()
    [[ -n "$CHAT_TEMPLATE" ]] && EXTRA_LLAMA_ARGS+=(--chat-template-file "$CHAT_TEMPLATE")
    if [[ "$MODEL_CHOICE" == "super" ]]; then
        CACHE_TYPE_K="q8_0"
        CACHE_TYPE_V="q5_0"
        EXTRA_LLAMA_ARGS+=(--context-shift --flash-attn on --cache-type-k "$CACHE_TYPE_K" --cache-type-v "$CACHE_TYPE_V")
    fi

    # Read the model's own trained context length (and KV-cache dimensions)
    # straight from the GGUF header, and cap CTX_SIZE down to it -- this is
    # the fix for the 2026-09-06 incident: LLMSRV_CTX_SIZE's 262144 default
    # was being applied to every model regardless of what it was actually
    # trained for (Qwen3-4B: 40960, 6.4x smaller), massively over-sizing the
    # KV cache. Larger-context models (nemotron's hybrid archs, trained past
    # 1M) are unaffected since 262144 was already below their real ceiling.
    # If introspection fails (no python3/gguf-py, or an unrecognized
    # architecture), CONTEXT_LENGTH/HEAD_COUNT_KV/etc. stay unset -- CTX_SIZE
    # keeps its pre-existing value and check_mem falls back to a
    # weights-only estimate, same as before this change.
    unset ARCH BLOCK_COUNT CONTEXT_LENGTH HEAD_COUNT_KV KEY_LENGTH VALUE_LENGTH
    local meta_out
    if meta_out="$(gguf_meta "$MODEL")" && [[ -n "$meta_out" ]]; then
        eval "$meta_out"
    fi
    if [[ -n "${CONTEXT_LENGTH:-}" ]] && (( CONTEXT_LENGTH > 0 )) && (( CTX_SIZE > CONTEXT_LENGTH )); then
        echo "llmsrv.sh: capping --ctx-size ${CTX_SIZE} -> ${CONTEXT_LENGTH} (${MODEL_LABEL}'s own trained context; set LLMSRV_CTX_SIZE explicitly to override)" >&2
        CTX_SIZE="$CONTEXT_LENGTH"
    fi
}

# Each alias gets its own default port (models/aliases.json's "port" field)
# so multiple models can run as parallel systemd --user services without
# colliding; LLMSRV_PORT still wins as an explicit override; a bare
# absolute-path invocation (no alias entry) falls back to 8091 (see
# DEFAULT_PORT set in the case block above).
PORT="${LLMSRV_PORT:-$DEFAULT_PORT}"

# Tag the API-visible alias (not MODEL_LABEL -- that feeds the unit/file
# names) when this script isn't running on PRIMARY_HOST, so a consumer like
# Open WebUI can tell at a glance that a model came from another machine.
[[ "$(hostname)" != "$PRIMARY_HOST" ]] && MODEL_ALIAS="${MODEL_ALIAS} (remote)"

UNIT_NAME="llmsrv-${MODEL_LABEL}.service"
UNIT_FILE="${UNIT_DIR}/${UNIT_NAME}"

# check_mem — refuse to start if there isn't enough free+reclaimable memory
# to hold the model weights AND the KV cache at the (now-capped) CTX_SIZE,
# plus a runtime-overhead margin, rather than letting it OOM (or thrash
# swap) partway through a multi-minute load. MemAvailable already folds in
# reclaimable page cache, so a low reading here isn't stale cache -- on
# this GB10 box it's usually another llmsrv unit's model still resident, or
# its GPU/UVM pool, which the driver doesn't hand back to the OS the
# instant the process exits.
#
# KV-cache sizing uses BLOCK_COUNT/HEAD_COUNT_KV/KEY_LENGTH/VALUE_LENGTH
# from gguf_meta (set above, right after model resolution). Hybrid
# Mamba/SSM architectures (nemotron_h, nemotron_h_moe -- super/nano/
# nemotron-nano-4b) report HEAD_COUNT_KV=0 since this simple
# per-transformer-layer formula doesn't apply to their SSM layers; for
# those, kv_bytes stays 0 and required_gib is weights+margin only, exactly
# the pre-existing (pre-2026-09-06-fix) behavior -- MEM_MARGIN_GIB was
# already covering that case adequately (see
# node-2-gb10-uma-memory-leak.md's "super" headroom notes).
check_mem() {
    [[ -f "$MODEL" ]] || return 0  # model-missing case is reported separately

    local model_bytes model_gib kv_bytes kv_gib kv_note k_bytes v_bytes
    local avail_kib avail_gib required_gib other_units hint

    model_bytes="$(stat -c %s "$MODEL")"
    model_gib=$(( model_bytes / 1024 / 1024 / 1024 ))

    kv_bytes=0
    kv_note="KV cache not modeled for this architecture"
    if [[ -n "${HEAD_COUNT_KV:-}" ]] && (( HEAD_COUNT_KV > 0 )) \
        && [[ -n "${BLOCK_COUNT:-}" && -n "${KEY_LENGTH:-}" && -n "${VALUE_LENGTH:-}" ]]; then
        k_bytes="$(kv_type_bytes "$CACHE_TYPE_K")"
        v_bytes="$(kv_type_bytes "$CACHE_TYPE_V")"
        kv_bytes=$(( BLOCK_COUNT * CTX_SIZE * HEAD_COUNT_KV * (KEY_LENGTH * k_bytes + VALUE_LENGTH * v_bytes) ))
        kv_note="KV cache ~$(( kv_bytes / 1024 / 1024 / 1024 ))GiB @ ctx ${CTX_SIZE}"
    fi
    kv_gib=$(( kv_bytes / 1024 / 1024 / 1024 ))
    required_gib=$(( model_gib + kv_gib + MEM_MARGIN_GIB ))

    avail_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    avail_gib=$(( avail_kib / 1024 / 1024 ))
    echo "llmsrv.sh: ${MODEL_LABEL} needs ~${required_gib}GiB (weights ${model_gib}GiB + ${kv_note} + ${MEM_MARGIN_GIB}GiB margin); ${avail_gib}GiB available" >&2
    (( avail_gib >= required_gib )) && return 0

    # Near miss: sync and try an opportunistic drop_caches before giving up.
    # This can't dig out anything MemAvailable didn't already count as
    # reclaimable, but the estimate rounds conservatively, so a real reclaim
    # sometimes recovers a few hundred MB right at the edge. sudo -n fails
    # fast (no prompt) if passwordless sudo isn't set up -- fine either way,
    # this stays optional and start/stop/restart still need no sudo.
    sync
    sudo -n sh -c 'echo 1 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    avail_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    avail_gib=$(( avail_kib / 1024 / 1024 ))
    (( avail_gib >= required_gib )) && return 0

    other_units="$(systemctl --user list-units --type=service --state=running --no-legend --plain 'llmsrv-*.service' 2>/dev/null \
        | awk -v skip="$UNIT_NAME" '$1 != skip {print $1}')"

    hint="Free up memory or stop other processes first."
    [[ -n "$other_units" ]] && hint="Stop the other running llmsrv unit(s) first: ${other_units//$'\n'/, }"

    die "not enough available memory: need ~${required_gib}GiB (weights ${model_gib}GiB + ${kv_note} + ${MEM_MARGIN_GIB}GiB margin), only ${avail_gib}GiB available (see 'free -h'). ${hint}"
}

# write_unit — render the systemd --user unit for the resolved model and
# (re)write it to disk. Called by do_start/do_restart so the unit always
# reflects the current MODEL/MODEL_ALIAS/CHAT_TEMPLATE before starting.
# EXTRA_LLAMA_ARGS (chat-template-file, and super's context-shift/flash-attn/
# cache-type flags) was already built once, right after model resolution --
# shared with check_mem's KV-cache sizing via CACHE_TYPE_K/CACHE_TYPE_V, so
# it isn't duplicated here.
write_unit() {
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=llmsrv.sh - ${MODEL_ALIAS} (llama-server)
After=network.target

[Service]
Type=simple
WorkingDirectory=$(dirname "$LLAMA_SERVER")
ExecStart=${LLAMA_SERVER} --model ${MODEL} --alias "${MODEL_ALIAS}" ${EXTRA_LLAMA_ARGS[@]} --ctx-size ${CTX_SIZE} --n-gpu-layers 99 --load-mode none --threads 8 --temp 1.0 --top-p 0.95 --min-p 0.01 --reasoning-preserve --host ${HOST} --port ${PORT}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
}

do_status() {
    if systemctl --user is-active --quiet "$UNIT_NAME"; then
        echo "running: ${MODEL_LABEL}, unit ${UNIT_NAME}, port ${PORT}"
        curl -s -m 3 "http://127.0.0.1:${PORT}/health" 2>&1 || echo "(health check failed -- still loading, or unreachable)"
    else
        echo "not running: ${MODEL_LABEL}"
        systemctl --user is-failed --quiet "$UNIT_NAME" 2>/dev/null && \
            echo "(unit ${UNIT_NAME} last exited with a failure -- see 'journalctl --user -u ${UNIT_NAME}')"
    fi
}

do_stop() {
    if systemctl --user is-active --quiet "$UNIT_NAME"; then
        echo "stopping ${UNIT_NAME}..."
        systemctl --user stop "$UNIT_NAME"
        echo "stopped"
    else
        echo "not running"
    fi
}

# wait_for_healthy_or_die -- poll the freshly-started unit until it answers
# /health, but bail out (and STOP the unit) the moment either it exits on
# its own or MemAvailable collapses below CRITICAL_MEM_GIB -- whichever
# comes first. This is what the 2026-09-06 node-1 incident was missing:
# do_start used to fire-and-forget (`systemctl start` then immediately
# print "check later with status"), so nothing was watching when a
# forced --ctx-size massively over-sized the KV cache and the resulting
# allocation pressure wedged a driver-internal lock (nvidia-smi included)
# for 16+ minutes before the kernel's own hung-task detector even caught
# up -- by then the box was already unrecoverable, with no OOM-killer and
# no hardware watchdog to fall back on.
#
# Polling MemAvailable every 2s here catches that same collapse in
# seconds, not minutes. Stopping the unit -- not just detecting the
# problem -- is the point: Restart=on-failure only helps once a process
# has actually exited, and a wedged process holding a driver lock never
# gets there on its own. check_mem's pre-flight estimate should prevent
# most of these outright; this is the backstop for when the estimate is
# wrong (e.g. hybrid-architecture models where KV cache isn't modeled) or
# something else on the box is competing for the same shared pool.
wait_for_healthy_or_die() {
    local waited=0 avail_gib

    while (( waited < START_TIMEOUT_SEC )); do
        if curl -sf -m 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
            return 0
        fi

        if ! systemctl --user is-active --quiet "$UNIT_NAME"; then
            die "${UNIT_NAME} exited during startup -- see 'journalctl --user -u ${UNIT_NAME}'"
        fi

        avail_gib=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
        if (( avail_gib < CRITICAL_MEM_GIB )); then
            systemctl --user stop "$UNIT_NAME"
            die "aborted ${UNIT_NAME}: MemAvailable dropped to ${avail_gib}GiB (< ${CRITICAL_MEM_GIB}GiB floor) during startup -- stopped it before the driver wedged instead of letting it keep running. Lower --ctx-size (LLMSRV_CTX_SIZE), stop other GPU-resident processes, or raise LLMSRV_CRITICAL_MEM_GIB if this is a known-safe dip for this model."
        fi

        sleep 2
        waited=$(( waited + 2 ))
    done

    systemctl --user stop "$UNIT_NAME"
    die "${UNIT_NAME} did not report healthy within ${START_TIMEOUT_SEC}s -- stopped it (see 'journalctl --user -u ${UNIT_NAME}'). Raise LLMSRV_START_TIMEOUT_SEC if this model just needs longer to load."
}

do_start() {
    if systemctl --user is-active --quiet "$UNIT_NAME"; then
        die "already running (${MODEL_LABEL}, unit ${UNIT_NAME}) -- use '$0 --model $MODEL_CHOICE restart' or 'stop' first"
    fi
    [[ -x "$LLAMA_SERVER" ]] || die "llama-server not found/executable at $LLAMA_SERVER"
    [[ -f "$MODEL" ]] || die "model not found at $MODEL"
    [[ -z "$CHAT_TEMPLATE" || -f "$CHAT_TEMPLATE" ]] || die "chat template not found at $CHAT_TEMPLATE"
    resolve_launch_config
    check_mem

    write_unit
    systemctl --user start "$UNIT_NAME"

    echo "waiting for ${MODEL_LABEL} to report healthy (up to ${START_TIMEOUT_SEC}s, watching MemAvailable)..."
    wait_for_healthy_or_die

    echo "started: ${MODEL_LABEL}, unit ${UNIT_NAME}, port ${PORT}"
    echo "logs: journalctl --user -u ${UNIT_NAME} -f"
}

case "${1:-start}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; do_start ;;
    status)  do_status ;;
    *) die "usage: $0 [--model <name>|<path>] [start|stop|status|restart]" ;;
esac

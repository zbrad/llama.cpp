#!/usr/bin/env bash
# ~/nemo.sh — launch a nemotron model via bare llama-server as a
# systemd --user service (no sudo needed for start/stop/restart), with
# all the fixes worked out this session (see the -home-zbrad-gh project
# memory's tuned-builds-expansion-plan.md for the full writeup of each):
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
#
# Usage: ~/nemo.sh [--model <name-from-models/aliases.json>|<path>] [start|stop|status|restart]
#   (--model defaults to 'super'; command defaults to 'start')
#   Known model names, their filenames, aliases, and chat templates come
#   from models/aliases.json in the llama.cpp checkout -- see that file's
#   own comment for the search-path resolution it uses.
#
# Process management: generates and drives a systemd --user unit
# (nemo-<alias>.service) rather than a bare nohup'd background process --
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
HOST="${NEMO_HOST:-0.0.0.0}"
CTX_SIZE="${NEMO_CTX_SIZE:-262144}"
MEM_MARGIN_GIB="${NEMO_MEM_MARGIN_GIB:-8}"  # headroom above model size for KV cache + overhead
PRIMARY_HOST="${NEMO_PRIMARY_HOST:-node-2}"  # host consumers (e.g. Open WebUI) run on; anywhere else is "remote"

die() { echo "error: $*" >&2; exit 1; }

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

# Each alias gets its own default port (models/aliases.json's "port" field)
# so multiple models can run as parallel systemd --user services without
# colliding; NEMO_PORT still wins as an explicit override; a bare
# absolute-path invocation (no alias entry) falls back to 8091 (see
# DEFAULT_PORT set in the case block above).
PORT="${NEMO_PORT:-$DEFAULT_PORT}"

# Tag the API-visible alias (not MODEL_LABEL -- that feeds the unit/file
# names) when this script isn't running on PRIMARY_HOST, so a consumer like
# Open WebUI can tell at a glance that a model came from another machine.
[[ "$(hostname)" != "$PRIMARY_HOST" ]] && MODEL_ALIAS="${MODEL_ALIAS} (remote)"

UNIT_NAME="nemo-${MODEL_LABEL}.service"
UNIT_FILE="${UNIT_DIR}/${UNIT_NAME}"

# check_mem — the model itself is ~86GB; refuse to start if there isn't
# enough free+reclaimable memory to load it plus a safety margin for KV
# cache/runtime overhead, rather than letting it OOM (or silently swap)
# partway through a multi-minute load. MemAvailable already folds in
# reclaimable page cache, so a low reading here isn't stale cache -- on
# this GB10 box it's usually another nemo unit's model still resident, or
# its GPU/UVM pool, which the driver doesn't hand back to the OS the
# instant the process exits.
check_mem() {
    [[ -f "$MODEL" ]] || return 0  # model-missing case is reported separately

    local model_bytes model_gib avail_kib avail_gib required_gib other_units hint

    model_bytes="$(stat -c %s "$MODEL")"
    model_gib=$(( model_bytes / 1024 / 1024 / 1024 ))
    required_gib=$(( model_gib + MEM_MARGIN_GIB ))

    avail_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    avail_gib=$(( avail_kib / 1024 / 1024 ))
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

    other_units="$(systemctl --user list-units --type=service --state=running --no-legend --plain 'nemo-*.service' 2>/dev/null \
        | awk -v skip="$UNIT_NAME" '$1 != skip {print $1}')"

    hint="Free up memory or stop other processes first."
    [[ -n "$other_units" ]] && hint="Stop the other running nemo unit(s) first: ${other_units//$'\n'/, }"

    die "not enough available memory: need ~${required_gib}GiB (model ${model_gib}GiB + ${MEM_MARGIN_GIB}GiB margin), only ${avail_gib}GiB available (see 'free -h'). ${hint}"
}

# write_unit — render the systemd --user unit for the resolved model and
# (re)write it to disk. Called by do_start/do_restart so the unit always
# reflects the current MODEL/MODEL_ALIAS/CHAT_TEMPLATE before starting.
write_unit() {
    local extra_args=()
    [[ -n "$CHAT_TEMPLATE" ]] && extra_args+=(--chat-template-file "$CHAT_TEMPLATE")
    # super-only: long-context agent-loop settings (context-shift so a run
    # doesn't hard-reset on hitting the ctx limit; flash-attn + quantized
    # KV cache to keep long-context VRAM/RAM in check). --n-gpu-layers 99
    # below already offloads every layer (super has far fewer than 99), so
    # no separate "999"/"all" override is needed. --no-mmap is intentionally
    # NOT added: this build's own --help marks it deprecated in favor of
    # --load-mode none, already set below (see script header comment).
    if [[ "$MODEL_CHOICE" == "super" ]]; then
        extra_args+=(--context-shift --flash-attn on --cache-type-k q8_0 --cache-type-v q5_0)
    fi

    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=nemo.sh - ${MODEL_ALIAS} (llama-server)
After=network.target

[Service]
Type=simple
WorkingDirectory=$(dirname "$LLAMA_SERVER")
ExecStart=${LLAMA_SERVER} --model ${MODEL} --alias "${MODEL_ALIAS}" ${extra_args[@]} --ctx-size ${CTX_SIZE} --n-gpu-layers 99 --load-mode none --threads 8 --temp 1.0 --top-p 0.95 --min-p 0.01 --reasoning-preserve --host ${HOST} --port ${PORT}
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

do_start() {
    if systemctl --user is-active --quiet "$UNIT_NAME"; then
        die "already running (${MODEL_LABEL}, unit ${UNIT_NAME}) -- use '$0 --model $MODEL_CHOICE restart' or 'stop' first"
    fi
    [[ -x "$LLAMA_SERVER" ]] || die "llama-server not found/executable at $LLAMA_SERVER"
    [[ -f "$MODEL" ]] || die "model not found at $MODEL"
    [[ -z "$CHAT_TEMPLATE" || -f "$CHAT_TEMPLATE" ]] || die "chat template not found at $CHAT_TEMPLATE"
    check_mem

    write_unit
    systemctl --user start "$UNIT_NAME"

    echo "started: ${MODEL_LABEL}, unit ${UNIT_NAME}, port ${PORT}"
    echo "logs: journalctl --user -u ${UNIT_NAME} -f"
    echo "(large models take a while to load -- check with '$0 --model $MODEL_CHOICE status')"
}

case "${1:-start}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; do_start ;;
    status)  do_status ;;
    *) die "usage: $0 [--model <name>|<path>] [start|stop|status|restart]" ;;
esac

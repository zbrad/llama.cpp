#!/usr/bin/env bash
# ~/nemo.sh — launch a nemotron model locally via bare llama-server, in the
# background, with all the fixes worked out this session (see the
# -home-zbrad-gh project memory's tuned-builds-expansion-plan.md for the
# full writeup of each):
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
set -euo pipefail

REPODIR="/home/zbrad/gh/llama.cpp"
LLAMA_SERVER="${REPODIR}/build/bin/llama-server"
ALIASES_FILE="${REPODIR}/models/aliases.json"
LOG_DIR="${REPODIR}/logs"
PORT="${NEMO_PORT:-8091}"
HOST="${NEMO_HOST:-0.0.0.0}"
CTX_SIZE="${NEMO_CTX_SIZE:-32768}"
MEM_MARGIN_GIB="${NEMO_MEM_MARGIN_GIB:-8}"  # headroom above model size for KV cache + overhead
PRIMARY_HOST="${NEMO_PRIMARY_HOST:-node-1}"  # host consumers (e.g. Open WebUI) run on; anywhere else is "remote"

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

# Tag the API-visible alias (not MODEL_LABEL -- that feeds filenames) when
# this script isn't running on PRIMARY_HOST, so a consumer like Open WebUI
# can tell at a glance that a model came from another machine.
[[ "$(hostname)" != "$PRIMARY_HOST" ]] && MODEL_ALIAS="${MODEL_ALIAS} (remote)"

PID_FILE="/home/zbrad/.nemo-${MODEL_LABEL}.pid"

# running_pid — checks both the pidfile *and* (defensively) any stray
# llama-server already serving this exact model, in case a prior instance
# was started outside this script (bit us once already this session).
running_pid() {
    local pid
    if [[ -f "$PID_FILE" ]]; then
        pid="$(cat "$PID_FILE")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    pid="$(pgrep -f "llama-server.*${MODEL}" | head -1 || true)"
    [[ -n "$pid" ]] && echo "$pid" && return 0
    return 1
}

# check_mem — the model itself is ~86GB; refuse to start if there isn't
# enough free+reclaimable memory to load it plus a safety margin for KV
# cache/runtime overhead, rather than letting it OOM (or silently swap)
# partway through a multi-minute load.
check_mem() {
    [[ -f "$MODEL" ]] || return 0  # model-missing case is reported separately

    local model_bytes model_gib avail_kib avail_gib required_gib
    model_bytes="$(stat -c %s "$MODEL")"
    model_gib=$(( model_bytes / 1024 / 1024 / 1024 ))
    avail_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    avail_gib=$(( avail_kib / 1024 / 1024 ))
    required_gib=$(( model_gib + MEM_MARGIN_GIB ))

    if (( avail_gib < required_gib )); then
        die "not enough available memory: need ~${required_gib}GiB (model ${model_gib}GiB + ${MEM_MARGIN_GIB}GiB margin), only ${avail_gib}GiB available (see 'free -h'). Free up memory or stop other processes first."
    fi
}

do_status() {
    local pid
    if pid="$(running_pid)"; then
        echo "running: ${MODEL_LABEL}, pid $pid, port ${PORT}"
        curl -s -m 3 "http://127.0.0.1:${PORT}/health" 2>&1 || echo "(health check failed -- still loading, or unreachable)"
    else
        echo "not running: ${MODEL_LABEL}"
    fi
}

do_stop() {
    local pid
    if pid="$(running_pid)"; then
        echo "stopping pid $pid..."
        kill "$pid"
        until ! kill -0 "$pid" 2>/dev/null; do sleep 1; done
        rm -f "$PID_FILE"
        echo "stopped"
    else
        echo "not running"
    fi
}

do_start() {
    local existing
    if existing="$(running_pid)"; then
        die "already running (${MODEL_LABEL}, pid $existing) -- use '$0 --model $MODEL_CHOICE restart' or 'stop' first"
    fi
    [[ -x "$LLAMA_SERVER" ]] || die "llama-server not found/executable at $LLAMA_SERVER"
    [[ -f "$MODEL" ]] || die "model not found at $MODEL"
    [[ -z "$CHAT_TEMPLATE" || -f "$CHAT_TEMPLATE" ]] || die "chat template not found at $CHAT_TEMPLATE"
    check_mem

    mkdir -p "$LOG_DIR"
    local log="${LOG_DIR}/${MODEL_LABEL}-$(date +%Y%m%d-%H%M%S).log"

    local extra_args=()
    [[ -n "$CHAT_TEMPLATE" ]] && extra_args+=(--chat-template-file "$CHAT_TEMPLATE")

    cd "$(dirname "$LLAMA_SERVER")"
    nohup ./llama-server \
        --model "$MODEL" \
        --alias "$MODEL_ALIAS" \
        "${extra_args[@]}" \
        --ctx-size "$CTX_SIZE" \
        --n-gpu-layers 99 \
        --load-mode none \
        --threads 8 \
        --temp 1.0 --top-p 0.95 --min-p 0.01 \
        --reasoning-preserve \
        --host "$HOST" --port "$PORT" \
        > "$log" 2>&1 &
    local pid=$!
    disown
    echo "$pid" > "$PID_FILE"

    echo "started: ${MODEL_LABEL}, pid $pid, port ${PORT}"
    echo "log: $log"
    echo "(large models take a while to load -- check with '$0 --model $MODEL_CHOICE status')"
}

case "${1:-start}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; do_start ;;
    status)  do_status ;;
    *) die "usage: $0 [--model <name>|<path>] [start|stop|status|restart]" ;;
esac

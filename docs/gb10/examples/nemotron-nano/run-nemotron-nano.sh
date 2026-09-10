#!/usr/bin/env bash
# Example launch script for Nemotron-3-Nano-30B-A3B via llama-server on a
# DGX Spark (GB10) box. See ../../nemotron-nano-gb10.md for flag rationale.
#
# Adjust BIN/MODEL for your own layout. Model choice: Nano (~38 GiB) instead
# of Super (~65-81 GiB, see ../../nemotron-super-spark.md) leaves headroom
# for other GPU-resident workloads sharing the same unified-memory pool -
# size this against whatever else is running on your box.

set -euo pipefail

BIN="${LLAMA_BIN:-./build/bin/llama-server}"
MODEL="${LLAMA_MODEL:-./models/Nemotron-3-Nano-30B-A3B-UD-Q8_K_XL.gguf}"
HOST="${LLAMA_HOST:-0.0.0.0}"
PORT="${LLAMA_PORT:-8080}"
CTX_SIZE="${LLAMA_CTX_SIZE:-32768}"
NGL="${LLAMA_NGL:-all}"

# On-disk slot KV-cache: without --slot-save-path, llama-server only keeps
# the (already-default) in-RAM prompt cache, so nothing survives a server
# restart and clients can't explicitly save/restore a conversation's KV
# state via the /slots save|restore API. --cache-reuse lets the RAM cache
# reuse a matching prompt prefix via KV shifting instead of only exact
# matches (0 = off by default).
SLOT_CACHE_DIR="${LLAMA_SLOT_CACHE_DIR:-./slot-cache}"
mkdir -p "$SLOT_CACHE_DIR"

# --load-mode none: GB10's default load path (mmap) does a synchronous
# cudaMemcpyAsync per tensor off cold mmap pages (~259 MB/s); reading
# straight off disk into pinned staging buffers instead hits ~1131 MB/s,
# a 4.4x faster load. Replaces the older, now-deprecated --no-mmap/--mmap
# flags. See ../../nemotron-nano-gb10.md and ../../README.md for the full
# root-cause writeup.
LOAD_MODE="${LLAMA_LOAD_MODE:-none}"

# Sampling and reasoning-format per NVIDIA's Nemotron-3 docs (build.nvidia.com
# NIM reference) and Unsloth's llama.cpp guide for this GGUF: temp=1.0/top_p=0.95
# for all of chat/reasoning/tool-calling, min_p=0.01 for llama.cpp specifically.
# --reasoning-format deepseek splits <think>...</think> into message.reasoning_content
# instead of leaving it inline in content (this template advertises
# supports_preserve_reasoning; llama-server's own startup NOTICE flags this gap
# if left unset, along with a separate NOTICE for --reasoning-preserve). Current
# builds default --reasoning-format to auto rather than none, so this is no
# longer strictly required to get the split, but is kept explicit here to pin
# the behavior rather than rely on auto-detection.
exec "$BIN" \
  -m "$MODEL" \
  --host "$HOST" \
  --port "$PORT" \
  -ngl "$NGL" \
  -c "$CTX_SIZE" \
  --load-mode "$LOAD_MODE" \
  --jinja \
  --temp 1.0 \
  --top-p 0.95 \
  --min-p 0.01 \
  --reasoning-format deepseek \
  --reasoning-preserve \
  --slot-save-path "$SLOT_CACHE_DIR" \
  --cache-reuse 256

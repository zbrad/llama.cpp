# Nemotron-3-Nano on DGX Spark - llama.cpp Settings

## Model Facts

- **Model**: nvidia/nemotron-3-nano-30b-a3b
- **Architecture**: MoE - 30B total, **3B active** parameters
- **Chat template**: ChatML-style (`<|im_start|>`/`<|im_end|>`), jinja
  `enable_thinking` toggle, `<think>`/`</think>` reasoning tags
- **Quantization used**: `UD-Q8_K_XL` (Unsloth Dynamic quant), ~38 GiB on
  disk - fits comfortably alongside other GPU-resident workloads on a
  121 GiB unified-memory Spark box, unlike Nemotron-3-Super's ~65-81 GiB
  footprint (see [nemotron-super-spark.md](nemotron-super-spark.md))

## Recommended Sampling

Per NVIDIA's Nemotron-3 docs (build.nvidia.com NIM reference) the same
sampling settings apply across chat, reasoning, and tool-calling for both
Nano and Super:

- `temperature=1.0`
- `top_p=0.95`

Unsloth's llama.cpp-specific guide for this GGUF additionally recommends
`min_p=0.01`. These are **not** llama.cpp's own defaults (`temp=1.0,
top_p=1.0, top_k=40, min_p=0.05`) - confirm via `/props` after launch if
in doubt, since a bare `llama-server` invocation silently falls back to the
generic defaults rather than anything model-specific.

## llama.cpp Launch Flags

```bash
llama-server \
  --model nemotron-3-nano.UD-Q8_K_XL.gguf \
  --host 0.0.0.0 \
  --port 8080 \
  --ctx-size 32768 \
  --n-gpu-layers 99 \
  --jinja \
  --temp 1.0 --top-p 0.95 --min-p 0.01 \
  --reasoning-format deepseek \
  --reasoning-preserve \
  --slot-save-path /path/to/slot-cache \
  --cache-reuse 256
```

Flag notes:

- `--reasoning-format deepseek` splits `<think>...</think>` content into
  `message.reasoning_content` in the API response instead of leaving it
  inline in `content`. The chat template advertises
  `supports_preserve_reasoning`; llama-server's own startup log flags this
  with a NOTICE if the format is left at its default (`none`).
- `--reasoning-preserve` keeps the full reasoning trace across turns
  instead of truncating past turns down to only their final answer
  (the template's default `truncate_history_thinking` behavior). Without
  it, llama-server logs a separate NOTICE ("chat template supports
  preserving reasoning, consider enabling it").
- `--slot-save-path` plus `--cache-reuse 256` enable an on-disk KV-cache
  for slots (via the `/slots/{id}?action=save|restore` API and KV-shift
  based prefix reuse). Without `--slot-save-path`, llama-server only keeps
  the in-RAM prompt cache (`--cache-prompt`, enabled by default), so
  nothing survives a server restart.

## Deploying as a systemd Service

See [examples/nemotron-nano/](examples/nemotron-nano/) for a working
launch script, systemd unit template, and install script. Nothing in these
is fixed to a particular user or path: `run-nemotron-nano.sh` reads its
model/host/port/context settings from environment variables, and
`install-nemotron-service.sh` renders `nemotron-nano.service.in` with the
current user/group and the script's own on-disk location before installing
it, so the same files work unmodified from any checkout. Override
`SERVICE_USER`/`SERVICE_GROUP` if you want the service to run as someone
other than whoever runs the install script. `Nano`'s smaller footprint
(~38 GiB vs Super's ~65-81 GiB) still needs to be sized
against whatever else shares the same unified-memory pool (other model
servers, inference services, etc).

## References

- NVIDIA DGX Spark llama.cpp guide: https://build.nvidia.com/spark/llama-cpp/overview
- Nemotron-3-Nano model card: https://build.nvidia.com/nvidia/nemotron-3-nano-30b-a3b/modelcard
- Unsloth Nemotron-3 GGUF guide: https://unsloth.ai/docs/models/nemotron-3
- [nemotron-super-spark.md](nemotron-super-spark.md) - the larger sibling
  model, same hardware

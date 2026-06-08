# Nemotron-3-Super on DGX Spark — llama.cpp Settings

## Model Facts

- **Model**: nvidia/nemotron-3-super-120b-a12b
- **Architecture**: Hybrid Latent MoE — 120B total, **12B active** parameters
- **Context**: up to 1M tokens (use `262144` safely on a single GPU)
- **Positional encoding**: NoPE (No Positional Embeddings) — no YaRN scaling needed
- **Reasoning tokens**: `<think>` / `</think>` (token IDs 12 / 13)
- **Languages**: English, French, German, Italian, Japanese, Spanish, Chinese
- **Training cutoff**: February 2026

## Quantization Options

| Quant     | VRAM   | Notes                                      |
|-----------|--------|--------------------------------------------|
| Q4_K_XL   | ~65 GB | Recommended for DGX Spark — 14.4 tok/s    |
| FP8       | ~60 GB | Official NVIDIA checkpoint, <1% loss vs BF16 |
| INT4      | ~30 GB | Extreme memory constraint only             |

## llama.cpp Launch Flags

```bash
llama-server \
  --model nemotron-3-super.Q4_K_XL.gguf \
  --ctx-size 262144 \        # safe single-GPU limit (up to 1M with enough VRAM)
  --n-gpu-layers 99 \        # offload all layers to GPU
  --threads 8 \
  --temp 0.6 --top-p 0.95 \ # reasoning ON
  # --temp 0 \               # reasoning OFF (greedy decoding)
  --min-p 0.01 \
  --special --verbose-prompt # shows <think> reasoning tokens
```

## Build llama.cpp for DGX Spark (GB10 GPU)

```bash
cmake -B build -DGGML_CUDA=ON
cmake --build build --config Release -j$(nproc)
```

## Spark Integration

- Serve via `llama-server`'s OpenAI-compatible HTTP API
- Point Spark workers at the server endpoint
- DGX Spark GB10 achieves **14.4 tok/s** at Q4_K_XL, sub-second TTFT

## References

- NVIDIA DGX Spark llama.cpp guide: https://build.nvidia.com/spark/llama-cpp/overview
- Nemotron-3-Super model card: https://build.nvidia.com/nvidia/nemotron-3-super-120b-a12b/modelcard
- Unsloth step-by-step GGUF guide: https://unsloth.ai/docs/models/nemotron-3/nemotron-3-super
- llama.cpp perf discussion: https://github.com/ggml-org/llama.cpp/discussions/20421

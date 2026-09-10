#!/usr/bin/env python3
"""Build a tiny synthetic GGUF that reproduces the Ollama-native
nemotron_h_moe "latent-FFN" fingerprint, for testing the compat shim's
refuse-and-point-at-Unsloth behavior in src/llama-ollama-compat.cpp
(see docs/gb10/ollama-compat.md) without needing the real 87GB model.

The shim's detection (nemotron_h_moe_has_latent_tensors) only checks for
the presence of a blk.0/1.ffn_latent_in tensor on a nemotron_h_moe-arch
GGUF -- it never reads real weights, so a single near-empty tensor with
the right name and architecture KV is enough to trigger it.

Usage:
    PYTHONPATH=gguf-py python3 tuned/fixtures/make-nemotron-h-moe-latent-fixture.py out.gguf
    build/bin/llama-cli -m out.gguf -p hi -n 1
    # expect: "...llama.cpp does not support loading this non-standard
    # layout directly. Download a standard-format GGUF..." then a clean
    # non-zero exit, not a crash or a raw tensor-shape-mismatch error.
"""

import sys

import numpy as np

from gguf import GGUFWriter


def main() -> None:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <out.gguf>", file=sys.stderr)
        raise SystemExit(1)

    writer = GGUFWriter(sys.argv[1], "nemotron_h_moe")
    writer.add_name("nemotron-h-moe-latent-fixture")
    # Deliberately no nemotron_h_moe.moe_latent_size key -- that absence,
    # together with the ffn_latent_in tensor below, is the fingerprint.
    writer.add_tensor("blk.1.ffn_latent_in.weight", np.zeros((4, 4), dtype=np.float32))

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()


if __name__ == "__main__":
    main()

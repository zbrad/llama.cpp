#!/usr/bin/env python3
"""Regression-check fixture: a nemotron_h_moe GGUF with an mtp.* tensor but
NO ffn_latent_in tensor. This should still be silently skip-and-loaded (not
refused) -- see docs/gb10/ollama-compat.md's "Only mtp.* tensors present"
row. Pairs with make-nemotron-h-moe-latent-fixture.py, which covers the
refuse case.

Usage:
    PYTHONPATH=gguf-py python3 tuned/fixtures/make-nemotron-h-moe-mtp-only-fixture.py out.gguf
"""

import sys

import numpy as np

from gguf import GGUFWriter


def main() -> None:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <out.gguf>", file=sys.stderr)
        raise SystemExit(1)

    writer = GGUFWriter(sys.argv[1], "nemotron_h_moe")
    writer.add_name("nemotron-h-moe-mtp-only-fixture")
    writer.add_tensor(
        "mtp.layers.0.mixer.experts.0.up_proj.weight",
        np.zeros((4, 4), dtype=np.float32),
    )

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()


if __name__ == "__main__":
    main()

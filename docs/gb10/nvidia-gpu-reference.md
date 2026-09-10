# NVIDIA GPU Architecture Reference

| Arch Name     | Arch Code | SM Code | CUDA Support | Host Arch          | Common Name | SKUs                                                        |
|---------------|-----------|---------|--------------|-------------------|-------------|-------------------------------------------------------------|
| Volta         | 7.0       | 70      | 9.0 – 12.x   | x86_64            | v100        | V100 PCIe, V100 SXM2                                        |
| Volta         | 7.2       | 72      | 9.2 – 12.x   | aarch64           | xavier      | Jetson AGX Xavier                                           |
| Turing        | 7.5       | 75      | 10.0+        | x86_64            | rtx_20xx    | RTX 2080/2070/2060, T4, Quadro RTX                          |
| Ampere        | 8.0       | 80      | 11.0+        | x86_64, aarch64   | a100        | A100 PCIe, A100 SXM4                                        |
| Ampere        | 8.6       | 86      | 11.1+        | x86_64            | rtx_30xx    | RTX 3090/3080/3070, A10, A30, A40                           |
| Ampere        | 8.7       | 87      | 11.4+        | aarch64           | orin        | Jetson AGX Orin                                             |
| Ada Lovelace  | 8.9       | 89      | 11.8+        | x86_64            | rtx_40xx    | RTX 4090/4080/4070, L40, L4                                 |
| Hopper        | 9.0       | 90      | 11.8+        | x86_64, aarch64   | h100        | H100 PCIe, H100 SXM5, H200                                  |
| Blackwell     | 10.0      | 100     | 12.8+        | x86_64, aarch64   | b200        | B100, B200                                                  |
| Blackwell     | 10.0a     | 100a    | 12.8+        | x86_64, aarch64   | gb200       | GB200 NVL72                                                 |
| Blackwell     | 10.1      | 101     | 12.8+        | x86_64            | b20         | B20 (embedded/inference variant)                            |
| Blackwell     | 12.0      | 120     | 12.8+        | x86_64            | rtx_50xx    | RTX 5090/5080/5070 (GeForce Blackwell)                      |
| Blackwell     | 12.1      | 121     | 13.2+        | aarch64           | spark       | GB10 (DGX Spark, NVLink-C2C)                                |

## Notes

- **SM code** is what goes in `CMAKE_CUDA_ARCHITECTURES` (e.g. `121-real`)
- **`-real`** generates device SASS for that SM only — no PTX fallback
- **`-virtual`** generates PTX only — JIT-compiled at runtime, forward compatible
- **`-real;-virtual`** together = SASS + PTX (largest binary, most portable)
- SM 103 appears in CCCL cmake lists but does not correspond to a known shipping GPU
- Fat binary for all Blackwell: `100-real;101-real;120-real;121-real`
- Minimum SM for cuVS/RAPIDS: **75** (Turing)

## Sources

- [NVIDIA CUDA GPUs — Compute Capability](https://developer.nvidia.com/cuda-gpus) — canonical per-GPU compute-capability list
- [CUDA C++ Programming Guide — Compute Capabilities](https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#compute-capabilities) — feature availability per SM version
- [CMake `CUDA_ARCHITECTURES` property](https://cmake.org/cmake/help/latest/prop_tgt/CUDA_ARCHITECTURES.html) — `-real` / `-virtual` suffix semantics
- GB10 / DGX Spark = sm_121 (compute capability 12.1), distinct from sm_120 (RTX 50-series) and sm_100 (B200/GB200):
  - [NVIDIA Developer Forums — DGX Spark GB10 CUDA Compute Capability](https://forums.developer.nvidia.com/t/dgx-spark-gb10-cuda-compute-capability/342864)
  - [PyTorch Forums — DGX Spark GB10 CUDA 13.0 SM_121](https://discuss.pytorch.org/t/dgx-spark-gb10-cuda-13-0-python-3-12-sm-121/223744)
  - [Kubesimplify — DGX Spark Unpacked: GB10, Unified Memory, sm_121](https://blog.kubesimplify.com/day-3-the-dgx-spark-unpacked-gb10-unified-memory-sm-121-and-the-one-reason-this-hardware-exists)

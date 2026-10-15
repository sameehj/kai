---
name: gpu-nvidia
description: NVIDIA GPU monitoring and CUDA diagnostics.
version: "1.0"
tags: [gpu, nvidia, cuda, monitoring]
requires:
  bins: [nvidia-smi]
---

# NVIDIA GPU

```bash
nvidia-smi
nvidia-smi dmon -s pucvmet -d 1
nvidia-smi pmon -s um -d 1
nvidia-smi --query-compute-apps=pid,name,used_gpu_memory --format=csv
```

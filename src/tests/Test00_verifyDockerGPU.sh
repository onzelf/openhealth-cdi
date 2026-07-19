#!/usr/bin/env bash
set -euo pipefail

pass() { printf "\033[32m✓\033[0m %s\n" "$*"; }
fail() { printf "\033[31m✗\033[0m %s\n" "$*"; exit 1; }

command -v nvidia-smi >/dev/null \
  || fail "nvidia-smi is not installed on the host"
nvidia-smi >/dev/null \
  || fail "The NVIDIA driver is not operational"
pass "Host NVIDIA driver is operational"

docker info >/dev/null 2>&1 \
  || fail "Docker daemon is unavailable"

docker run --rm --gpus all ubuntu:22.04 nvidia-smi >/dev/null \
  || fail "Docker cannot expose the GPU; configure NVIDIA Container Toolkit"
pass "Docker --gpus all exposes the NVIDIA GPU"

if docker image inspect openhealth/flower-client:local >/dev/null 2>&1
then
  docker run --rm --gpus all \
    --entrypoint python \
    openhealth/flower-client:local \
    -c 'import torch; assert torch.__version__ == "2.2.0+cu121"; assert torch.version.cuda == "12.1"; assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0))'
  pass "Flower client image sees CUDA with torch 2.2.0+cu121"
else
  echo "Flower client image not built yet; image-level check skipped."
  echo "Run this script again after tofu apply."
fi

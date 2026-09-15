#!/usr/bin/env bash
set -euo pipefail

pass() { printf "\033[32m✓\033[0m %s\n" "$*"; }
info() { printf "\033[36m→\033[0m %s\n" "$*"; }
fail() { printf "\033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# ------------------------------------------------------------
# Test0A — compute backend detection
#
# Contract:
#   no NVIDIA GPU hardware      -> COMPUTE_BACKEND=cpu
#   NVIDIA GPU + healthy stack  -> COMPUTE_BACKEND=cuda
#   NVIDIA GPU + broken stack   -> FAIL
#
# This test determines the available compute backend.
# It does not require GPU acceleration.
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPUTE_TFVARS="${REPO_ROOT}/src/infra/tofu/compute.auto.tfvars"

write_compute_backend() {
    local backend="$1"
    printf 'compute_backend = "%s"\n' "$backend" > "$COMPUTE_TFVARS"
    echo "COMPUTE_BACKEND=$backend"
}


docker info >/dev/null 2>&1 \
  || fail "Docker daemon is unavailable"

pass "Docker daemon is available"

# Detect NVIDIA display/compute hardware independently of the driver.
# NVIDIA PCI vendor ID = 0x10de.
NVIDIA_GPU_PRESENT=0

if [[ -d /sys/bus/pci/devices ]]; then
  while IFS= read -r vendor_file; do
    [[ "$(cat "$vendor_file" 2>/dev/null || true)" == "0x10de" ]] || continue

    device_dir="$(dirname "$vendor_file")"
    class="$(cat "${device_dir}/class" 2>/dev/null || true)"

    # PCI class 0x03xxxx = display controller, including VGA/3D devices.
    if [[ "$class" == 0x03* ]]; then
      NVIDIA_GPU_PRESENT=1
      break
    fi
  done < <(find /sys/bus/pci/devices -maxdepth 2 -name vendor -type f 2>/dev/null)
fi

if [[ "$NVIDIA_GPU_PRESENT" -eq 0 ]]; then
  info "No NVIDIA GPU hardware detected"
  pass "Compute backend selected: CPU"
  write_compute_backend cpu
  exit 0
fi

info "NVIDIA GPU hardware detected"

# Hardware exists. From this point onward, failure means that the
# NVIDIA host/container stack is misconfigured, not that CPU should
# silently be selected.

command -v nvidia-smi >/dev/null 2>&1 \
  || fail "NVIDIA GPU detected but nvidia-smi is not installed"

nvidia-smi >/dev/null 2>&1 \
  || fail "NVIDIA GPU detected but the NVIDIA driver is not operational"

pass "NVIDIA host driver is operational"

docker run --rm --gpus all ubuntu:22.04 nvidia-smi >/dev/null 2>&1 \
  || fail "NVIDIA GPU detected but Docker cannot expose it; check NVIDIA Container Toolkit"

pass "Docker can expose the NVIDIA GPU"

# If the current Flower client image already exists, verify that its
# CUDA runtime can actually use the detected GPU. Do not require a
# specific GPU model.
if docker image inspect openhealth/flower-client:local >/dev/null 2>&1; then
  docker run --rm --gpus all \
    --entrypoint python \
    openhealth/flower-client:local \
    -c '
import torch
assert torch.cuda.is_available(), "CUDA unavailable to PyTorch"
print(
    "torch=" + torch.__version__,
    "cuda_runtime=" + str(torch.version.cuda),
    "device=" + torch.cuda.get_device_name(0),
    "capability=" + str(torch.cuda.get_device_capability(0)),
)
'
  pass "Existing Flower client image can use the NVIDIA GPU"
else
  info "Flower client image not built yet; image-level CUDA check skipped"
fi

pass "Compute backend selected: CUDA"
write_compute_backend cuda

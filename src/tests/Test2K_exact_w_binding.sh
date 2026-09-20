#!/usr/bin/env bash
set -euo pipefail

# Test2K — exact-W behavioral Gatekeeper test.
#
# Builds the current Gatekeeper source into a disposable image and executes
# Test2K_exact_w_binding_unit.py inside it. No running OpenHealth stack,
# Redis service, certificates, or existing state are required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GATEKEEPER_DIR="${SRC_DIR}/vfp-governance/gatekeeper"
TEST_FILE="${SCRIPT_DIR}/Test2K_exact_w_binding_unit.py"
IMAGE="openhealth-test2k-exact-w:${USER:-local}"

for cmd in docker; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing command: ${cmd}" >&2
    exit 1
  }
done

[[ -s "${TEST_FILE}" ]] || {
  echo "Missing test file: ${TEST_FILE}" >&2
  exit 1
}

docker build -q -t "${IMAGE}" "${GATEKEEPER_DIR}" >/dev/null

docker run --rm \
  -v "${TEST_FILE}:/tmp/Test2K_exact_w_binding_unit.py:ro" \
  --entrypoint python \
  "${IMAGE}" \
  /tmp/Test2K_exact_w_binding_unit.py

#!/usr/bin/env bash
set -euo pipefail

# Test0C — final OpenHealth-CDI delivery regression
#
# Runs the delivery readiness and Mode 1B evidence chain:
#
#   Test0B -> Test5A -> Test5C -> Test5D -> Test5E
#
# Usage:
#   ./src/tests/Test0C_delivery_regression.sh <active-envelope-id> <host-ip>
#
# Test5D output is also captured as the JMIR Table 7 evidence artifact.

EID="${1:-}"
HOST_IP="${2:-}"

if [[ -z "${EID}" || -z "${HOST_IP}" ]]; then
    echo "Usage: $0 <active-envelope-id> <host-ip>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

section() {
    printf '\n============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

section "DELIVERY PREFLIGHT — Test0B"
"${SCRIPT_DIR}/Test0B_delivery_preflight.sh" "${EID}" "${HOST_IP}"

section "HAL ISOLATION — Test5A"
LAN_IP="${HOST_IP}" \
    "${SCRIPT_DIR}/Test5A_agent_isolation.sh"

section "HAL CREDENTIAL ADMISSION — Test5C"
"${SCRIPT_DIR}/Test5C_agent_credential_admission.sh" "${EID}"

section "TABLE 7 DECISION PLANE — Test5D"
"${SCRIPT_DIR}/Test5D_mode1b_table7_conformance.sh" "${EID}" 2>&1 \
    | tee "${REPO_ROOT}/JMIR_paper/table7/Test5D_mode1b_conformance.txt"

section "MODE 1B GOVERNANCE COMPOSITION — Test5E"
"${SCRIPT_DIR}/Test5E_mode1b_contextual_agent.sh" "${EID}"

section "DELIVERY REGRESSION GREEN"
printf '✓ Test0B delivery preflight\n'
printf '✓ Test5A Hal isolation\n'
printf '✓ Test5C Hal credential admission\n'
printf '✓ Test5D Table 7 decision plane\n'
printf '✓ Test5E Mode 1B governance composition\n'
printf '\n✓ ALL DELIVERY GATES GREEN\n'

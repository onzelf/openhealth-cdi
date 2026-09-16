#!/usr/bin/env bash
set -euo pipefail

# OpenHealth-CDI WSL cold-start bootstrap.
#
# Contract:
#   1. Prove that the expected Docker Desktop  / OpenTofu substrate is
#      coherent before touching the running deployment.
#   2. Refuse to proceed if persistent identity or issuer state is missing.
#   3. Only then replace the disposable container layer and reconcile it from
#      OpenTofu, preserving the existing networks and persistent volumes.
#
# Usage:
#   ./demo_start.sh
#
# VERIFIER_IP may override the expected host-side address of verifier.local.
# It defaults to 127.0.0.1 for the local WSL deployment.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOFU_DIR="${REPO_ROOT}/src/infra/tofu"
KEY_DIR="${REPO_ROOT}/src/vfp-governance/verifier/vault/holder_keys"
GEN_KEYS="${REPO_ROOT}/src/tools/gen_member_keys.py"
PATHMNIST_HOST="${PATHMNIST_HOST:-${REPO_ROOT}/../data/pathmnist.npz}"
EXPECTED_VERIFIER_IP="${VERIFIER_IP:-127.0.0.1}"

CA="${REPO_ROOT}/src/vfp-governance/verifier/certs/ca.crt"
HUB_CRT="${REPO_ROOT}/src/vfp-governance/verifier/certs/hub.crt"
HUB_KEY="${REPO_ROOT}/src/vfp-governance/verifier/certs/hub.key"

ISSUER_IMAGE="fcac/issuer:local"
HAL_IMAGE="openhealth/hal:local"

CONTAINERS=(
  flower-client-a
  flower-client-b
  flower-client-c
  hal
  flower-server
  fcac-frontend
  fc-hub
  issuer-proxy
  issuer-hospitala
  issuer-hospitalb
  verifier-proxy
  verifier-app
  redis
  holder-signer
)

EXPECTED_CONTAINERS=("${CONTAINERS[@]}")

fail() {
  echo
  echo "OPENHEALTH DEMO START: FAIL"
  echo "$1"
  exit 1
}

pass() {
  echo "OK  $1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

require_file() {
  [[ -s "$1" ]] || fail "Missing or empty file: $1"
}

tofu_state_id() {
  local address="$1"
  tofu state show -no-color "${address}" 2>/dev/null \
    | awk -F'= ' '/^[[:space:]]*id[[:space:]]*=/{gsub(/"/, "", $2); print $2; exit}'
}

registry_record() {
  local volume="$1"
  local registry_file="$2"
  local subject="$3"

  docker run --rm \
    -v "${volume}:/vault/registry:ro" \
    --entrypoint python \
    "${ISSUER_IMAGE}" \
    -c '
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
subject = sys.argv[2]
if not path.is_file():
    raise SystemExit(10)
registry = json.loads(path.read_text())
record = registry.get(subject)
if not isinstance(record, dict):
    raise SystemExit(11)
print(json.dumps(record, sort_keys=True))
' \
    "/vault/registry/${registry_file}" \
    "${subject}"
}

check_member_identity() {
  local volume="$1"
  local registry_file="$2"
  local subject="$3"
  local private_key="$4"

  local record
  local derived
  local registry_jkt
  local registry_pub
  local derived_jkt
  local derived_pub

  record="$(registry_record "${volume}" "${registry_file}" "${subject}")" \
    || fail "Issuer registry ${volume} does not contain ${subject}."

  derived="$(
    python3 "${GEN_KEYS}" \
      --derive \
      --private-key "${private_key}" \
      --format json
  )" || fail "Cannot derive holder identity from ${private_key}."

  registry_jkt="$(jq -r '.jkt // empty' <<<"${record}")"
  registry_pub="$(jq -r '.pub_b64 // empty' <<<"${record}")"
  derived_jkt="$(jq -r '.jkt // empty' <<<"${derived}")"
  derived_pub="$(jq -r '.pub_b64 // empty' <<<"${derived}")"

  [[ -n "${registry_jkt}" && -n "${registry_pub}" ]] \
    || fail "Incomplete issuer registry identity for ${subject}."

  [[ "${registry_jkt}" == "${derived_jkt}" ]] \
    || fail "Issuer JKT for ${subject} does not match the persisted private key."

  [[ "${registry_pub}" == "${derived_pub}" ]] \
    || fail "Issuer public key for ${subject} does not match the persisted private key."

  pass "${subject} issuer registration matches persisted holder key"
}

echo "OpenHealth-CDI cold demo startup"
echo

# ------------------------------------------------------------
# 0. Local commands
# ------------------------------------------------------------

echo "[0/9] Checking local commands..."
for cmd in docker tofu jq python3 curl getent awk; do
  require_cmd "${cmd}"
done
pass "Required commands available"

# ------------------------------------------------------------
# 1. Docker runtime
# ------------------------------------------------------------

echo
echo "[1/9] Checking Docker runtime..."

for _ in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

docker info >/dev/null 2>&1 || fail "Docker is not ready."

pass "Docker daemon is reachable"

# ------------------------------------------------------------
# 2. verifier.local invariant
# ------------------------------------------------------------
#
# EC2 can use:
# VERIFIER_IP="$HOST_IP" ./src/tools/demo_start.sh

echo
echo "[2/9] Checking verifier.local..."

getent hosts verifier.local >/dev/null 2>&1 \
  || fail "verifier.local is not resolvable."

getent hosts verifier.local \
  | awk '{print $1}' \
  | grep -qx "${EXPECTED_VERIFIER_IP}" \
  || fail "verifier.local does not resolve to ${EXPECTED_VERIFIER_IP}."

pass "verifier.local -> ${EXPECTED_VERIFIER_IP}"

# ------------------------------------------------------------
# 3. Host-backed persistent material
# ------------------------------------------------------------

echo
echo "[3/9] Checking host-backed persistent demo material..."

for holder in Audrey Bob Charlie; do
  require_file "${KEY_DIR}/${holder}.privhex"
done

require_file "${GEN_KEYS}"
require_file "${PATHMNIST_HOST}"
require_file "${CA}"
require_file "${HUB_CRT}"
require_file "${HUB_KEY}"

find "${REPO_ROOT}" -path '*/runs/*/model.pt' -type f -print -quit \
  | grep -q . \
  || fail "No persisted model.pt found."

pass "Holder keys, model, PathMNIST and TLS material present"

# ------------------------------------------------------------
# 4. OpenTofu ownership and Docker object identity
# ------------------------------------------------------------

echo
echo "[4/9] Checking OpenTofu <-> Docker ownership..."

cd "${TOFU_DIR}"

WORKSPACE="$(tofu workspace show 2>/dev/null || true)"
[[ "${WORKSPACE}" == "default" ]] \
  || fail "Unexpected OpenTofu workspace '${WORKSPACE:-unknown}'. Expected default."

STATE_LIST="$(tofu state list 2>/dev/null)" \
  || fail "Cannot read OpenTofu state."

REQUIRED_STATE=(
  docker_network.fc
  docker_network.agent_edge
  docker_volume.issuer_registry_hospitala
  docker_volume.issuer_registry_hospitalb
  docker_volume.hal_identity
)

for address in "${REQUIRED_STATE[@]}"; do
  grep -qx "${address}" <<<"${STATE_LIST}" \
    || fail "OpenTofu state does not own required resource: ${address}"
done

for network in fc agent-edge; do
  docker network inspect "${network}" >/dev/null 2>&1 \
    || fail "Required Docker network is missing: ${network}"
done

for volume in issuer-registry-hospitala issuer-registry-hospitalb hal-identity; do
  docker volume inspect "${volume}" >/dev/null 2>&1 \
    || fail "Required Docker volume is missing: ${volume}"
done

TOFU_FC_ID="$(tofu_state_id docker_network.fc)"
TOFU_AGENT_ID="$(tofu_state_id docker_network.agent_edge)"
DOCKER_FC_ID="$(docker network inspect -f '{{.Id}}' fc)"
DOCKER_AGENT_ID="$(docker network inspect -f '{{.Id}}' agent-edge)"

[[ -n "${TOFU_FC_ID}" && "${TOFU_FC_ID}" == "${DOCKER_FC_ID}" ]] \
  || fail "OpenTofu and Docker disagree on network fc."

[[ -n "${TOFU_AGENT_ID}" && "${TOFU_AGENT_ID}" == "${DOCKER_AGENT_ID}" ]] \
  || fail "OpenTofu and Docker disagree on network agent-edge."

for spec in \
  'docker_volume.issuer_registry_hospitala:issuer-registry-hospitala' \
  'docker_volume.issuer_registry_hospitalb:issuer-registry-hospitalb' \
  'docker_volume.hal_identity:hal-identity'
do
  address="${spec%%:*}"
  expected_name="${spec#*:}"
  state_id="$(tofu_state_id "${address}")"
  [[ "${state_id}" == "${expected_name}" ]] \
    || fail "OpenTofu volume identity mismatch for ${expected_name}."
done

pass "OpenTofu state and Docker networks/volumes are coherent"

# Record persistent object identity before any container removal.
FC_ID_BEFORE="${DOCKER_FC_ID}"
AGENT_ID_BEFORE="${DOCKER_AGENT_ID}"
ISSUER_A_CREATED_BEFORE="$(docker volume inspect -f '{{.CreatedAt}}' issuer-registry-hospitala)"
ISSUER_B_CREATED_BEFORE="$(docker volume inspect -f '{{.CreatedAt}}' issuer-registry-hospitalb)"
HAL_CREATED_BEFORE="$(docker volume inspect -f '{{.CreatedAt}}' hal-identity)"

# ------------------------------------------------------------
# 5. Persistent identity state
# ------------------------------------------------------------

echo
echo "[5/9] Checking issuer and agent identity state..."

docker image inspect "${ISSUER_IMAGE}" >/dev/null 2>&1 \
  || fail "Required existing issuer image is missing: ${ISSUER_IMAGE}"

docker image inspect "${HAL_IMAGE}" >/dev/null 2>&1 \
  || fail "Required existing Hal image is missing: ${HAL_IMAGE}"

check_member_identity \
  issuer-registry-hospitala \
  org__HospitalA.members.json \
  Audrey \
  "${KEY_DIR}/Audrey.privhex"

check_member_identity \
  issuer-registry-hospitalb \
  org__HospitalB.members.json \
  Bob \
  "${KEY_DIR}/Bob.privhex"

docker run --rm \
  -v hal-identity:/var/lib/hal/identity:ro \
  --entrypoint sh \
  "${HAL_IMAGE}" \
  -c 'test -s /var/lib/hal/identity/holder.key && test -s /var/lib/hal/identity/holder.jwk && test -s /var/lib/hal/identity/holder.jkt' \
  >/dev/null \
  || fail "Hal persistent holder identity is missing or incomplete."

pass "Issuer and Hal persistent identity state is intact"

# ------------------------------------------------------------
# 6. Remove disposable container layer
# ------------------------------------------------------------

echo
echo "[6/9] Removing previous OpenHealth containers..."

for container in "${CONTAINERS[@]}"; do
  if docker container inspect "${container}" >/dev/null 2>&1; then
    docker rm -f "${container}" >/dev/null
    echo "removed ${container}"
  fi
done

# ------------------------------------------------------------
# 7. Reconcile deployment from the already-validated OpenTofu state
# ------------------------------------------------------------
#
# main.tf uses edge_bind_ip 
# edge_bind_ip = "0.0.0.0"

echo
echo "[7/9] Applying OpenTofu deployment..."

cd "${TOFU_DIR}"

tofu apply -auto-approve

# Persistent networks and volumes must not have been replaced by the apply.
[[ "$(docker network inspect -f '{{.Id}}' fc)" == "${FC_ID_BEFORE}" ]] \
  || fail "Network fc was unexpectedly replaced during OpenTofu apply."

[[ "$(docker network inspect -f '{{.Id}}' agent-edge)" == "${AGENT_ID_BEFORE}" ]] \
  || fail "Network agent-edge was unexpectedly replaced during OpenTofu apply."

[[ "$(docker volume inspect -f '{{.CreatedAt}}' issuer-registry-hospitala)" == "${ISSUER_A_CREATED_BEFORE}" ]] \
  || fail "Hospital A issuer registry volume was unexpectedly replaced."

[[ "$(docker volume inspect -f '{{.CreatedAt}}' issuer-registry-hospitalb)" == "${ISSUER_B_CREATED_BEFORE}" ]] \
  || fail "Hospital B issuer registry volume was unexpectedly replaced."

[[ "$(docker volume inspect -f '{{.CreatedAt}}' hal-identity)" == "${HAL_CREATED_BEFORE}" ]] \
  || fail "Hal identity volume was unexpectedly replaced."

pass "OpenTofu preserved networks and persistent volumes"

# ------------------------------------------------------------
# 8. Runtime verification and PathMNIST staging
# ------------------------------------------------------------

echo
echo "[8/9] Checking containers and staging PathMNIST..."

sleep 3

for container in "${EXPECTED_CONTAINERS[@]}"; do
  status="$(
    docker inspect \
      --format '{{.State.Status}}' \
      "${container}" 2>/dev/null || true
  )"

  [[ "${status}" == "running" ]] \
    || fail "${container} is not running. Status=${status:-missing}"

  echo "OK  ${container}"
done

docker exec flower-server mkdir -p /tmp/medmnist
docker cp "${PATHMNIST_HOST}" flower-server:/tmp/medmnist/pathmnist.npz >/dev/null

docker exec flower-server \
  test -s /tmp/medmnist/pathmnist.npz \
  || fail "PathMNIST dataset is not visible inside flower-server."

pass "PathMNIST dataset staged in flower-server"

# ------------------------------------------------------------
# 9. Demo-specific functional preflight
# ------------------------------------------------------------

echo
echo "[9/9] Running demo preflight..."

for holder in Audrey Bob Charlie; do
  docker exec holder-signer \
    test -s "/vault/holder_keys/${holder}.privhex" \
    || fail "${holder} key is not visible inside holder-signer."
done
pass "Holder keys visible inside holder-signer"

docker exec flower-server \
  sh -c 'find /vault/runs -name model.pt -type f -print -quit | grep -q .' \
  || fail "Persisted model is not visible inside flower-server."
pass "Persisted model visible inside flower-server"

docker exec hal \
  sh -c 'test -s /var/lib/hal/identity/holder.key && test -s /var/lib/hal/identity/holder.jwk && test -s /var/lib/hal/identity/holder.jkt' \
  || fail "Hal identity is not visible inside the Hal container."
pass "Hal identity visible"

# Re-check issuer identity after container replacement.
check_member_identity \
  issuer-registry-hospitala \
  org__HospitalA.members.json \
  Audrey \
  "${KEY_DIR}/Audrey.privhex"

check_member_identity \
  issuer-registry-hospitalb \
  org__HospitalB.members.json \
  Bob \
  "${KEY_DIR}/Bob.privhex"

VERIFIER_HEALTH="$(
  curl -fsS --max-time 10 \
    --cacert "${CA}" \
    --cert "${HUB_CRT}" \
    --key "${HUB_KEY}" \
    https://verifier.local:8443/health
)" || fail "Verifier TLS edge is not reachable through verifier.local."

jq -e '.ok == true' <<<"${VERIFIER_HEALTH}" >/dev/null \
  || fail "Verifier health response is not OK."
pass "verifier.local TLS/Gatekeeper path operational"

curl -fsS http://127.0.0.1:8082/ >/dev/null \
  || fail "Dashboard is not reachable on http://127.0.0.1:8082/"
pass "Dashboard reachable"

echo
echo "========================================"
echo "OPENHEALTH DEMO READY"
echo "http://127.0.0.1:8082/"
echo "========================================"

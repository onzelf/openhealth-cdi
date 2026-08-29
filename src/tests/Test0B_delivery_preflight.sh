#!/usr/bin/env bash
set -u

# OpenHealth-CDI deterministic delivery preflight.
# Read-only by design. It does not select envelopes, mint credentials,
# restart containers, retrain, or modify governance state.
#
# Usage:
#   ./src/tests/Test00_delivery_preflight.sh <active-envelope-id> <host-ip>

EID="${1:-}"
HOST_IP="${2:-${HOST_IP:-}}"

[[ -n "${EID}" ]] || {
  echo "Usage: $0 <active-envelope-id> <host-ip>" >&2
  exit 2
}
[[ -n "${HOST_IP}" ]] || {
  echo "ERROR: host-ip is required" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
HUB_CRT="${SRC_DIR}/vfp-governance/verifier/certs/hub.crt"
HUB_KEY="${SRC_DIR}/vfp-governance/verifier/certs/hub.key"
ADMIN_A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
ADMIN_A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"
ADMIN_B_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.crt"
ADMIN_B_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalB-admin.key"

FAILURES=0

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
section() {
  printf '\n============================================================\n%s\n============================================================\n' "$1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

container_running() {
  local c="$1"
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)"
  [[ "$running" == "true" ]] && pass "container ${c} running" || fail "container ${c} not running"
}

section "0. Local prerequisites"
for cmd in docker curl jq python3; do
  require_cmd "$cmd"
done

for f in \
  "$CA" "$HUB_CRT" "$HUB_KEY" \
  "$ADMIN_A_CRT" "$ADMIN_A_KEY" \
  "$ADMIN_B_CRT" "$ADMIN_B_KEY"
do
  [[ -s "$f" ]] && pass "present: ${f}" || fail "missing: ${f}"
done

section "1. Required containers"
for c in \
  redis \
  verifier-app verifier-proxy \
  issuer-hospitala issuer-hospitalb issuer-proxy \
  holder-signer \
  fc-hub fcac-frontend \
  flower-server flower-client-a flower-client-b \
  hal
do
  container_running "$c"
done

section "2. Hub boundary"
BOUNDARY="$(curl -fsS --max-time 5 http://127.0.0.1:8080/administration/boundary 2>/dev/null || true)"

if [[ -z "$BOUNDARY" ]]; then
  fail "direct Hub boundary unavailable"
else
  pass "direct Hub boundary reachable"

  SELECTED="$(jq -r '.selected_envelope_id // empty' <<<"$BOUNDARY")"
  if [[ "$SELECTED" == "$EID" ]]; then
    pass "selected envelope matches ${EID}"
  else
    fail "selected envelope mismatch: expected ${EID}, got ${SELECTED:-none}"
  fi
fi

section "3. Flower backend registration"
BACKENDS="$(curl -fsS --max-time 5 http://127.0.0.1:8080/backend/list 2>/dev/null || true)"

if [[ -z "$BACKENDS" ]]; then
  fail "Hub backend registry unavailable"
else
  if jq -e '
    [.backends[]?
      | select(
          .backend_id == "flower-local"
          and .backend_type == "flower_server"
          and .url == "http://flower-server:8081"
        )
    ] | length == 1
  ' <<<"$BACKENDS" >/dev/null
  then
    pass "flower-local registered with Hub"
  else
    fail "flower-local missing or registered with unexpected contract"
  fi
fi

section "4. Flower readiness and envelope binding"
FLOWER_HEALTH="$(
  docker exec -i fc-hub python - "$EID" 2>/dev/null <<'PY' || true
import json
import sys
import requests

eid = sys.argv[1]
try:
    r = requests.get("http://flower-server:8081/health", timeout=5)
    print(json.dumps({
        "http_status": r.status_code,
        "body": r.json() if "application/json" in r.headers.get("content-type", "") else r.text,
        "expected_envelope_id": eid,
    }))
except Exception as exc:
    print(json.dumps({
        "http_status": None,
        "error": repr(exc),
        "expected_envelope_id": eid,
    }))
PY
)"

if jq -e \
  --arg e "$EID" '
    .http_status == 200
    and .body.status == "ok"
    and .body.backend_id == "flower-local"
    and .body.backend_type == "flower_server"
    and .body.bound_envelope_id == $e
  ' <<<"$FLOWER_HEALTH" >/dev/null 2>&1
then
  pass "Flower control service ready and bound to ${EID}"
else
  fail "Flower not ready or bound to wrong envelope"
  jq . <<<"$FLOWER_HEALTH" >&2 2>/dev/null || true
fi

section "5. Frontend-to-Hub path"
FRONT_BOUNDARY="$(curl -fsS --max-time 5 http://127.0.0.1:8082/api/administration/boundary 2>/dev/null || true)"

if [[ -z "$FRONT_BOUNDARY" ]]; then
  fail "frontend-to-Hub path unavailable"
else
  FRONT_SELECTED="$(jq -r '.selected_envelope_id // empty' <<<"$FRONT_BOUNDARY")"
  [[ "$FRONT_SELECTED" == "$EID" ]] \
    && pass "frontend reaches Hub and sees selected envelope" \
    || fail "frontend path sees unexpected selected envelope: ${FRONT_SELECTED:-none}"
fi

section "6. Verifier TLS edge"
VERIFIER_HEALTH="$(
  curl -fsS --max-time 5 \
    --resolve "verifier.local:8443:${HOST_IP}" \
    --cacert "$CA" \
    "https://verifier.local:8443/health" 2>/dev/null || true
)"

if [[ -n "$VERIFIER_HEALTH" ]]; then
  pass "verifier TLS health reachable with project CA"
else
  fail "verifier TLS health unavailable"
fi

section "7. Issuer mTLS edges"
ISSUER_A="$(
  curl -fsS --max-time 5 \
    --resolve "issuer-hospitala.local:9443:${HOST_IP}" \
    --cacert "$CA" \
    --cert "$ADMIN_A_CRT" \
    --key "$ADMIN_A_KEY" \
    "https://issuer-hospitala.local:9443/members" 2>/dev/null || true
)"
[[ -n "$ISSUER_A" ]] \
  && pass "Hospital A issuer mTLS path operational" \
  || fail "Hospital A issuer mTLS path unavailable"

ISSUER_B="$(
  curl -fsS --max-time 5 \
    --resolve "issuer-hospitalb.local:9443:${HOST_IP}" \
    --cacert "$CA" \
    --cert "$ADMIN_B_CRT" \
    --key "$ADMIN_B_KEY" \
    "https://issuer-hospitalb.local:9443/members" 2>/dev/null || true
)"
[[ -n "$ISSUER_B" ]] \
  && pass "Hospital B issuer mTLS path operational" \
  || fail "Hospital B issuer mTLS path unavailable"

section "8. Hal topology and local prerequisites"
HAL_NETWORKS="$(
  docker inspect hal 2>/dev/null |
    jq -r '.[0].NetworkSettings.Networks | keys | sort | join(",")' 2>/dev/null || true
)"
[[ "$HAL_NETWORKS" == "agent-edge" ]] \
  && pass "Hal attached only to agent-edge" \
  || fail "Hal network set unexpected: ${HAL_NETWORKS:-unknown}"

HUB_NETWORKS="$(
  docker inspect fc-hub 2>/dev/null |
    jq -r '.[0].NetworkSettings.Networks | keys | sort | join(",")' 2>/dev/null || true
)"
if [[ "$HUB_NETWORKS" == *"agent-edge"* && "$HUB_NETWORKS" == *"fc"* ]]; then
  pass "Hub bridges agent-edge and fc"
else
  fail "Hub network set unexpected: ${HUB_NETWORKS:-unknown}"
fi

docker exec hal test -s /var/lib/hal/identity/holder.jwk >/dev/null 2>&1 \
  && pass "Hal holder identity present" \
  || fail "Hal holder identity missing"

docker exec hal test -s /run/secrets/openai.env >/dev/null 2>&1 \
  && pass "Hal reasoning credential file present" \
  || fail "Hal reasoning credential file missing"

section "9. Hal isolation gate"
if LAN_IP="$HOST_IP" "$SCRIPT_DIR/Test5A_agent_isolation.sh"; then
  pass "Gate 5A isolation invariant GREEN"
else
  fail "Gate 5A isolation invariant failed"
fi

section "10. Preflight result"
if [[ "$FAILURES" -eq 0 ]]; then
  pass "DELIVERY PREFLIGHT GREEN"
  echo "Local prerequisites for governed Mode 1B execution are satisfied."
  echo "This preflight does not call the external reasoning provider and does not replace Test5E."
  exit 0
fi

fail "DELIVERY PREFLIGHT RED: ${FAILURES} check(s) failed"
echo "Do not run destructive recovery. Diagnose the first failed layer above." >&2
exit 1

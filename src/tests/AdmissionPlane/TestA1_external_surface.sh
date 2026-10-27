#!/usr/bin/env bash
set -uo pipefail

# TestA1_external_surface.sh
#
# Hypothesis:
#   An unauthenticated caller reaching the verifier edge must not be able to
#   invoke a state-mutating endpoint.
#
# Current candidate:
#   POST /bench/reset
#
# IMPORTANT:
#   /bench/reset clears benchmark samples only. It does not alter envelopes,
#   policy, credentials, or admission state. Run only when losing benchmark
#   samples is acceptable.
#
# Result meanings:
#   VULNERABILITY CONFIRMED  unauthenticated edge caller invoked /bench/reset.
#   ASSUMPTION REJECTED     edge required authentication/authorization.
#   INCONCLUSIVE            target unreachable or unrelated failure.
#
# Usage:
#   ./TestA1_external_surface.sh
#
# Optional:
#   VERIFIER_HOST=verifier.local
#   VERIFIER_PORT=8443
#   VERIFIER_IP=127.0.0.1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VERIFIER_HOST="${VERIFIER_HOST:-verifier.local}"
VERIFIER_PORT="${VERIFIER_PORT:-8443}"
VERIFIER_IP="${VERIFIER_IP:-127.0.0.1}"
BASE_URL="https://${VERIFIER_HOST}:${VERIFIER_PORT}"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"

inconclusive() {
  printf '\n? INCONCLUSIVE: %s\n' "$*" >&2
  exit 2
}

command -v curl >/dev/null 2>&1 || inconclusive "missing curl"
command -v jq >/dev/null 2>&1 || inconclusive "missing jq"
[[ -s "${CA}" ]] || inconclusive "missing CA file ${CA}"

CURL_BASE=(
  -sS
  --resolve "${VERIFIER_HOST}:${VERIFIER_PORT}:${VERIFIER_IP}"
  --cacert "${CA}"
)

echo "== Read-only reachability control: GET /health without client certificate =="

HEALTH_STATUS="$(
  curl "${CURL_BASE[@]}" \
    -o /tmp/openhealth-a1-health.$$ \
    -w '%{http_code}' \
    "${BASE_URL}/health"
)"
RC=$?
if [[ ${RC} -ne 0 ]]; then
  rm -f /tmp/openhealth-a1-health.$$
  inconclusive "verifier edge is not reachable at ${VERIFIER_IP}:${VERIFIER_PORT}"
fi

cat /tmp/openhealth-a1-health.$$ | jq . 2>/dev/null || true
rm -f /tmp/openhealth-a1-health.$$

[[ "${HEALTH_STATUS}" == "200" ]] || \
  inconclusive "health control returned HTTP ${HEALTH_STATUS}"

echo "✓ Verifier edge reachable without a client certificate"

echo
echo "== Attack: POST /bench/reset without client certificate =="

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

STATUS="$(
  curl "${CURL_BASE[@]}" \
    -o "${TMP}" \
    -w '%{http_code}' \
    -X POST \
    "${BASE_URL}/bench/reset"
)"
RC=$?

if [[ ${RC} -ne 0 ]]; then
  inconclusive "mutation request failed at transport/TLS layer"
fi

cat "${TMP}" | jq . 2>/dev/null || cat "${TMP}"

if [[ "${STATUS}" == "401" || "${STATUS}" == "403" ]]; then
  echo
  echo "✓ ASSUMPTION REJECTED: unauthenticated caller cannot invoke /bench/reset"
  exit 0
fi

if [[ "${STATUS}" != "200" ]]; then
  inconclusive "/bench/reset returned HTTP ${STATUS}"
fi

if jq -e '.ok == true and has("cleared")' "${TMP}" >/dev/null 2>&1; then
  echo
  echo "✗ VULNERABILITY CONFIRMED: unauthenticated verifier-edge caller invoked state-mutating /bench/reset"
  echo "  Scope: benchmark state only; this does not prove governance-state mutation."
  exit 1
fi

inconclusive "HTTP 200 response did not match the expected bench/reset contract"

#!/usr/bin/env bash
set -uo pipefail

# TestA4_external_hub_substitution.sh
#
# Hypothesis:
#   A caller reaching the application API without holder credentials must not
#   be able to cause the Hub to mint and exercise Bob's authority merely by
#   naming Bob.
#
# This is deliberately independent of Hal. It asks whether C2 is already
# reachable directly from the application edge.
#
# Result meanings:
#   VULNERABILITY CONFIRMED  unauthenticated caller caused Bob authority to be
#                            prepared and successfully exercised.
#   ASSUMPTION REJECTED     application edge refused the authority operation.
#   INCONCLUSIVE            prerequisite/setup/model failure.
#
# Current OpenTofu binds the frontend and Hub to 127.0.0.1. Therefore success
# with the default APP_URL demonstrates an application-edge vulnerability,
# NOT present Internet exposure. Set APP_URL to an externally reachable ingress
# to test actual remote reachability.
#
# Usage:
#   ./TestA4_external_hub_substitution.sh <active-envelope-id>
#
# Optional:
#   APP_URL=http://127.0.0.1:8082/api
#   TISSUE=colorectal_adenocarcinoma_epithelium

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
  echo "Usage: $0 <active-envelope-id>" >&2
  exit 2
}

APP_URL="${APP_URL:-http://127.0.0.1:8082/api}"
TISSUE="${TISSUE:-colorectal_adenocarcinoma_epithelium}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

inconclusive() {
  printf '\n? INCONCLUSIVE: %s\n' "$*" >&2
  exit 2
}

for cmd in curl jq; do
  command -v "${cmd}" >/dev/null 2>&1 || inconclusive "missing command ${cmd}"
done

case "${APP_URL}" in
  http://127.0.0.1*|https://127.0.0.1*|http://localhost*|https://localhost*)
    EXPOSURE="loopback"
    ;;
  *)
    EXPOSURE="external"
    ;;
esac

echo "Application edge : ${APP_URL}"
echo "Exposure class   : ${EXPOSURE}"
echo "Target principal : Bob"
echo "Requested tissue : ${TISSUE}"

echo
echo "== Control: unauthenticated application API is reachable =="

BOUNDARY_STATUS="$(
  curl -sS \
    -o "${TMP}/boundary.json" \
    -w '%{http_code}' \
    "${APP_URL}/administration/boundary"
)"
RC=$?

if [[ ${RC} -ne 0 ]]; then
  inconclusive "application edge is unreachable"
fi

if [[ "${BOUNDARY_STATUS}" == "401" || "${BOUNDARY_STATUS}" == "403" ]]; then
  echo
  echo "✓ ASSUMPTION REJECTED: application edge requires caller authentication"
  exit 0
fi

[[ "${BOUNDARY_STATUS}" == "200" ]] || \
  inconclusive "boundary control returned HTTP ${BOUNDARY_STATUS}"

SELECTED="$(
  jq -r '.selected_envelope_id // empty' "${TMP}/boundary.json"
)"

if [[ -z "${SELECTED}" ]]; then
  inconclusive "no envelope is currently selected"
fi

if [[ "${SELECTED}" != "${ENVELOPE_ID}" ]]; then
  inconclusive "selected envelope is ${SELECTED}, expected ${ENVELOPE_ID}"
fi

echo "✓ Application API reachable without caller credentials"

echo
echo "== Attack phase 1: attempt to make Hub acquire Bob ECT without Bob holder proof =="

MINT_STATUS="$(
  curl -sS \
    -o "${TMP}/mint.json" \
    -w '%{http_code}' \
    -X POST \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg e "${ENVELOPE_ID}" '{envelope_id:$e}')" \
    "${APP_URL}/administration/holders/Bob/mint-ect"
)"
RC=$?

if [[ ${RC} -ne 0 ]]; then
  inconclusive "Bob mint request failed at transport layer"
fi

cat "${TMP}/mint.json" | jq . 2>/dev/null || true

MINT_PREPARED="false"
MINT_DETAIL="$(jq -r '.detail // empty' "${TMP}/mint.json" 2>/dev/null || true)"

if [[ "${MINT_STATUS}" == "401" || "${MINT_STATUS}" == "403" ]]; then
  echo "✓ Phase 1 blocked: unauthenticated caller cannot prepare Bob authority"
elif [[ "${MINT_STATUS}" == "400" && "${MINT_DETAIL}" == "holder_mint_proof_required" ]]; then
  echo "✓ Phase 1 blocked: Bob holder proof is required to mint Bob authority"
elif [[ "${MINT_STATUS}" == "200" ]]; then
  jq -e '
    .principal=="Bob"
    and .ready==true
  ' "${TMP}/mint.json" >/dev/null || \
    inconclusive "HTTP 200 mint response did not establish a ready Bob credential"

  MINT_PREPARED="true"
  echo "! Phase 1 succeeded: unauthenticated caller caused Bob ECT preparation"
else
  inconclusive "Bob mint returned HTTP ${MINT_STATUS}"
fi

echo
echo "== Attack phase 2: attempt Bob authority exercise without Bob ECT/DPoP =="

INFER_STATUS="$(
  curl -sS \
    -o "${TMP}/infer.json" \
    -w '%{http_code}' \
    -X POST \
    -H 'content-type: application/json' \
    -d "$(
      jq -nc \
        --arg e "${ENVELOPE_ID}" \
        --arg r "${RUN_ID}" \
        --arg t "${TISSUE}" \
        '{
          principal:"Bob",
          envelope_id:$e,
          run_id:$r,
          requested_tissue:$t,
          topk:3
        }'
    )" \
    "${APP_URL}/user/inference"
)"
RC=$?

if [[ ${RC} -ne 0 ]]; then
  inconclusive "Bob inference request failed at transport layer"
fi

cat "${TMP}/infer.json" | jq . 2>/dev/null || true

if [[ "${INFER_STATUS}" == "401" || "${INFER_STATUS}" == "403" ]]; then
  INFER_DETAIL="$(jq -r '.detail // empty' "${TMP}/infer.json" 2>/dev/null || true)"
  echo
  if [[ "${MINT_PREPARED}" == "true" ]]; then
    echo "✓ ATTACK BLOCKED: Bob ECT preparation succeeded, but unauthenticated Bob authority exercise was refused (${INFER_DETAIL:-HTTP ${INFER_STATUS}})"
  else
    echo "✓ ATTACK BLOCKED: unauthenticated caller could neither prepare nor exercise Bob authority (${INFER_DETAIL:-HTTP ${INFER_STATUS}})"
  fi
  exit 0
fi

[[ "${INFER_STATUS}" == "200" ]] || \
  inconclusive "Bob inference returned HTTP ${INFER_STATUS}"

ALLOW="$(jq -r '.admission.allow // empty' "${TMP}/infer.json")"
EXECUTED="$(jq -r '.executed // empty' "${TMP}/infer.json")"
PRINCIPAL="$(jq -r '.principal // empty' "${TMP}/infer.json")"

if [[ "${PRINCIPAL}" == "Bob" && "${ALLOW}" == "true" && "${EXECUTED}" == "true" ]]; then
  echo
  if [[ "${EXPOSURE}" == "external" ]]; then
    echo "✗ VULNERABILITY CONFIRMED: external unauthenticated caller caused Bob authority substitution and execution without Bob holder credentials"
  else
    echo "✗ VULNERABILITY CONFIRMED: unauthenticated application-edge caller caused Bob authority substitution and execution without Bob holder credentials"
    echo "  Current default exposure is loopback; remote exploitability requires publishing/proxying this edge."
  fi
  exit 1
fi

if [[ "${ALLOW}" == "false" ]]; then
  REASON="$(jq -r '.admission.reason // "unknown"' "${TMP}/infer.json")"
  echo
  echo "✓ ASSUMPTION REJECTED: Gatekeeper denied substituted Bob authority (${REASON})"
  exit 0
fi

inconclusive "request did not produce a decisive ALLOW+execute or policy DENY"

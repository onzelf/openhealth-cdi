#!/usr/bin/env bash
set -euo pipefail

# Test3A — visible evidence for policy -> ECT -> Gatekeeper -> model execution
#
# Usage:
#   ./Test3A_run_pathmnist_e2e.sh <active-envelope-id>

ENVELOPE_ID="${1:-}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
ARTIFACT_RUN_ID="${ARTIFACT_RUN_ID:-}"

HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"
HTU="${HTU:-https://verifier.local/admission/check}"

ISSUER_A_CONTAINER="${ISSUER_A_CONTAINER:-issuer-hospitala}"
ISSUER_B_CONTAINER="${ISSUER_B_CONTAINER:-issuer-hospitalb}"

ISSUER_PROXY_IP="${ISSUER_PROXY_IP:-192.168.1.25}"
ISSUER_PROXY_PORT="${ISSUER_PROXY_PORT:-9443}"

CA_CRT="${CA_CRT:-../vfp-governance/verifier/certs/ca.crt}"
ADMIN_A_CRT="${ADMIN_A_CRT:-../vfp-governance/verifier/certs/HospitalA-admin.crt}"
ADMIN_A_KEY="${ADMIN_A_KEY:-../vfp-governance/verifier/certs/HospitalA-admin.key}"
ADMIN_B_CRT="${ADMIN_B_CRT:-../vfp-governance/verifier/certs/HospitalB-admin.crt}"
ADMIN_B_KEY="${ADMIN_B_KEY:-../vfp-governance/verifier/certs/HospitalB-admin.key}"

POLICY_JSON="${POLICY_JSON:-../vfp-governance/verifier/state/policy.json}"
HOLDER_KEYS_DIR="${HOLDER_KEYS_DIR:-../vfp-governance/verifier/vault/holder_keys}"
GEN_MEMBER_KEYS="${GEN_MEMBER_KEYS:-../tools/gen_member_keys.py}"

[[ -n "${ENVELOPE_ID}" ]] || {
  echo "Usage: $0 <active-envelope-id>" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
}

pass() {
  printf '\033[32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

section() {
  printf '\n============================================================\n'
  printf '%s\n' "$1"
  printf '============================================================\n'
}

for command in jq python3 curl docker; do
  need "${command}"
done

[[ -s "${POLICY_JSON}" ]] || fail "Missing policy.json: ${POLICY_JSON}"

for container in fc-hub flower-server issuer-hospitala issuer-hospitalb; do
  docker ps --format '{{.Names}}' | grep -qx "${container}" \
    || fail "Container is not running: ${container}"
done

if [[ -z "${ARTIFACT_RUN_ID}" ]]; then
  ARTIFACT_RUN_ID="$(
    docker exec flower-server \
      cat "/vault/${ENVELOPE_ID}/run.json" \
      | jq -er '.run_id'
  )" || fail "Unable to resolve artifact run for envelope ${ENVELOPE_ID}"
fi

docker exec flower-server \
  test -s "/vault/runs/${ARTIFACT_RUN_ID}/model.pt" \
  || fail "Missing model: /vault/runs/${ARTIFACT_RUN_ID}/model.pt"

printf 'Logical Hub run : %s\n' "${RUN_ID}"
printf 'Artifact run    : %s\n' "${ARTIFACT_RUN_ID}"

decode_jws_payload() {
  local token="$1"
  python3 - "${token}" <<'PY'
import base64
import json
import sys

parts = sys.argv[1].split(".")
if len(parts) != 3:
    raise SystemExit("not a compact JWS")

payload = parts[1]
payload += "=" * ((4 - len(payload) % 4) % 4)
print(json.dumps(
    json.loads(base64.urlsafe_b64decode(payload).decode("utf-8")),
    sort_keys=True,
))
PY
}

compute_policy_hash() {
  python3 - "${POLICY_JSON}" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys

policy = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
canonical = json.dumps(
    policy,
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=False,
).encode("utf-8")
print(base64.urlsafe_b64encode(hashlib.sha256(canonical).digest()).decode().rstrip("="))
PY
}

holder_identity() {
  local holder="$1"
  local private_key="${HOLDER_KEYS_DIR}/${holder}.privhex"

  [[ -s "${private_key}" ]] \
    || fail "Missing holder private key: ${private_key}"

  python3 "${GEN_MEMBER_KEYS}" \
    --derive \
    --private-key "${private_key}" \
    --format json
}

verify_member() {
  local org="$1"
  local holder="$2"
  local issuer_host="$3"
  local admin_crt="$4"
  local admin_key="$5"

  local identity expected_pub expected_jkt
  identity="$(holder_identity "${holder}")"
  expected_pub="$(jq -er '.pub_b64' <<<"${identity}")"
  expected_jkt="$(jq -er '.jkt' <<<"${identity}")"

  local response
  response="$(
    curl -sS \
      --resolve "${issuer_host}:${ISSUER_PROXY_PORT}:${ISSUER_PROXY_IP}" \
      --cacert "${CA_CRT}" \
      --cert "${admin_crt}" \
      --key "${admin_key}" \
      "https://${issuer_host}:${ISSUER_PROXY_PORT}/members"
  )"

  local count enrolled_pub enrolled_jkt
  count="$(
    jq -r \
      --arg sub "${holder}" \
      '[.members[] | select(.sub == $sub)] | length' \
      <<<"${response}"
  )"
  [[ "${count}" == "1" ]] \
    || fail "Expected one issuer enrollment for ${holder}, found ${count}"

  enrolled_pub="$(
    jq -er \
      --arg sub "${holder}" \
      '.members[] | select(.sub == $sub) | .pub_b64' \
      <<<"${response}"
  )"
  enrolled_jkt="$(
    jq -er \
      --arg sub "${holder}" \
      '.members[] | select(.sub == $sub) | .jkt' \
      <<<"${response}"
  )"

  [[ "${expected_pub}" == "${enrolled_pub}" ]] \
    || fail "${holder}: holder public key does not match issuer enrollment"
  [[ "${expected_jkt}" == "${enrolled_jkt}" ]] \
    || fail "${holder}: holder JKT does not match issuer enrollment"

  printf '%-8s verified in %-18s  jkt=%s\n' \
    "${holder}" "${org}" "${expected_jkt}"
}

mint_ect() {
  local issuer_container="$1"
  local holder="$2"

  docker exec -i "${issuer_container}" \
    python3 - "${holder}" "${ENVELOPE_ID}" <<'PY'
import json
import sys
import requests

holder, envelope_id = sys.argv[1:]

response = requests.post(
    "http://127.0.0.1:8080/mint",
    json={
        "sub": holder,
        "envelope_id": envelope_id,
    },
    timeout=20,
)

try:
    body = response.json()
except Exception:
    body = response.text

print(json.dumps({"status": response.status_code, "body": body}))
PY
}

extract_ect() {
  jq -r '.body.ect // .body.ect_jws // empty'
}

show_and_verify_ect() {
  local holder="$1"
  local profile_alias="$2"
  local policy_capset="$3"
  local policy_operation="$4"
  local ect="$5"

  local claims
  claims="$(decode_jws_payload "${ect}")"

  local expected_cap
  expected_cap="$(
    jq -c \
      --arg op "${policy_operation}" \
      '.ops[$op] | {resource, action, purpose, scope}' \
      "${POLICY_JSON}"
  )"

  local local_policy_hash
  local_policy_hash="$(compute_policy_hash)"

  echo
  printf '%s ECT\n' "${holder}"
  printf '  issuer entitlement profile: %s\n' "${profile_alias}"
  printf '  policy capset            : %s\n' "${policy_capset}"
  printf '  policy operation         : %s\n' "${policy_operation}"
  printf '  policy hash (local)      : %s\n' "${local_policy_hash}"
  printf '  policy hash (ECT)        : %s\n' \
    "$(jq -r '.policy.policy_hash' <<<"${claims}")"
  printf '  envelope_id (ECT)        : %s\n' \
    "$(jq -r '.envelope_id' <<<"${claims}")"
  printf '  holder jkt (ECT)         : %s\n' \
    "$(jq -r '.cnf.jkt' <<<"${claims}")"
  echo "  capability minted:"
  jq '.cap' <<<"${claims}"

  local holder_jkt
  holder_jkt="$(holder_identity "${holder}" | jq -er '.jkt')"

  jq -e \
    --arg hash "${local_policy_hash}" \
    --arg envelope_id "${ENVELOPE_ID}" \
    --arg holder_jkt "${holder_jkt}" \
    --argjson expected_cap "${expected_cap}" \
    '
      .policy.policy_hash == $hash
      and .envelope_id == $envelope_id
      and .cnf.jkt == $holder_jkt
      and (.cap | index($expected_cap)) != null
    ' <<<"${claims}" >/dev/null \
    || fail "${holder}: ECT does not match policy/envelope/holder"

  pass "${holder}: policy operation compiled into the minted ECT"
}

make_dpop() {
  local signer="$1"
  local nonce="$2"
  local jti="$3"

  local identity holder_pub_b64
  identity="$(holder_identity "${signer}")"
  holder_pub_b64="$(jq -er '.pub_b64' <<<"${identity}")"

  python3 ../tools/make_dpop_jwt_eddsa.py \
    "$(tr -d '\r\n' <"${HOLDER_KEYS_DIR}/${signer}.privhex")" \
    "${holder_pub_b64}" \
    "${nonce}" \
    "${jti}" \
    POST \
    "${HTU}" \
    "${ENVELOPE_ID}"
}

SUMMARY_ROWS=()

call_predict() {
  local title="$1"
  local credential_holder="$2"
  local ect="$3"
  local dpop_signer="$4"
  local tissue="$5"
  local expected_allow="$6"
  local expected_reason="${7:-}"

  local nonce="nonce-${dpop_signer}-${RANDOM}-$(date +%s%N)"
  local jti="jti-${dpop_signer}-${RANDOM}-$(date +%s%N)"
  local dpop
  dpop="$(make_dpop "${dpop_signer}" "${nonce}" "${jti}")"

  local request
  request="$(
    jq -nc \
      --arg envelope_id "${ENVELOPE_ID}" \
      --arg run_id "${RUN_ID}" \
      --arg tissue "${tissue}" \
      --arg jti "${jti}" \
      '{
        envelope_id: $envelope_id,
        run_id: $run_id,
        requested_tissues: [$tissue],
        jti: $jti,
        topk: 3
      }'
  )"

  echo
  echo "------------------------------------------------------------"
  echo "${title}"
  echo "------------------------------------------------------------"
  printf 'Credential holder : %s\n' "${credential_holder}"
  printf 'DPoP signer       : %s\n' "${dpop_signer}"
  echo "Hub request:"
  jq . <<<"${request}"

  echo "DPoP claims:"
  decode_jws_payload "${dpop}" \
    | jq '{htm, htu, nonce, jti, envelope_id}'

  local response
  response="$(
    curl -sS \
      -X POST "${HUB_URL}/predict" \
      -H 'Content-Type: application/json' \
      -H "Authorization: ECT ${ect}" \
      -H "DPoP: ${dpop}" \
      -H "X-DPoP-Nonce: ${nonce}" \
      --data "${request}"
  )"

  local allow reason executed predicted
  allow="$(jq -r '.admission.allow // false' <<<"${response}")"
  reason="$(jq -r '.admission.reason // "-"' <<<"${response}")"
  executed="$(jq -r '.executed // false' <<<"${response}")"
  predicted="$(jq -r '.prediction.prediction_tissue // "-"' <<<"${response}")"

  echo "Gatekeeper decision returned by Hub:"
  jq '.admission' <<<"${response}"
  if ! jq -e 'has("admission")' <<<"${response}" >/dev/null; then
    echo "Hub response:"
    jq . <<<"${response}"
  fi
  printf 'Backend executed: %s\n' "${executed}"

  if [[ "${executed}" == "true" ]]; then
    echo "Model result:"
    jq '.prediction | {
      sample_index,
      actual_label,
      requested_tissue,
      prediction_label,
      prediction_tissue,
      topk
    }' <<<"${response}"
  fi

  if [[ "${expected_allow}" == "true" ]]; then
    jq -e \
      --arg envelope_id "${ENVELOPE_ID}" \
      --arg artifact_run_id "${ARTIFACT_RUN_ID}" \
      --arg tissue "${tissue}" \
      '
        .admission.allow == true
        and .executed == true
        and .prediction.envelope_id == $envelope_id
        and .prediction.run_id == $artifact_run_id
        and .prediction.requested_tissue == $tissue
        and (.prediction.topk | length) > 0
      ' <<<"${response}" >/dev/null \
      || fail "${title}: expected ALLOW plus model execution"
  else
    jq -e \
      --arg reason "${expected_reason}" \
      '
        .admission.allow == false
        and .admission.reason == $reason
        and .executed == false
      ' <<<"${response}" >/dev/null \
      || fail "${title}: expected DENY reason ${expected_reason}"
  fi

  SUMMARY_ROWS+=("${credential_holder}|${dpop_signer}|${tissue}|${allow}|${reason}|${executed}|${predicted}")
  pass "${title}"
}

section "1. Authoritative policy subset"

jq '{
  policy_id: .meta.policy_id,
  manifest_id: .meta.manifest_id,
  version: .version,
  profiles: {
    other_tissue_reader:
      .cap_profiles["capset:pathmnist_other_tissue_reader"],
    cancer_associated_reader:
      .cap_profiles["capset:pathmnist_cancer_associated_reader"]
  },
  operations: {
    query_model_other_tissue_reader:
      .ops.query_model_other_tissue_reader,
    query_model_cancer_associated_reader:
      .ops.query_model_cancer_associated_reader
  },
  reserved_pathology_labels:
    .caveats.reserved_pathology_labels
}' "${POLICY_JSON}"

section "2. Verify the two enrolled cryptographic holders"

verify_member \
  "org://HospitalA" \
  Audrey \
  issuer-hospitala.local \
  "${ADMIN_A_CRT}" \
  "${ADMIN_A_KEY}"

verify_member \
  "org://HospitalB" \
  Bob \
  issuer-hospitalb.local \
  "${ADMIN_B_CRT}" \
  "${ADMIN_B_KEY}"

section "3. Mint ECTs and prove that they contain policy subsets"

MINT_A="$(mint_ect "${ISSUER_A_CONTAINER}" Audrey)"
[[ "$(jq -r '.status' <<<"${MINT_A}")" == "200" ]] \
  || fail "Audrey ECT mint failed: ${MINT_A}"
ECT_A="$(extract_ect <<<"${MINT_A}")"
[[ -n "${ECT_A}" ]] || fail "Audrey ECT is empty"

show_and_verify_ect \
  Audrey \
  PATHMNIST_OTHER_TISSUE_READER \
  capset:pathmnist_other_tissue_reader \
  query_model_other_tissue_reader \
  "${ECT_A}"

MINT_B="$(mint_ect "${ISSUER_B_CONTAINER}" Bob)"
[[ "$(jq -r '.status' <<<"${MINT_B}")" == "200" ]] \
  || fail "Bob ECT mint failed: ${MINT_B}"
ECT_B="$(extract_ect <<<"${MINT_B}")"
[[ -n "${ECT_B}" ]] || fail "Bob ECT is empty"

show_and_verify_ect \
  Bob \
  PATHMNIST_CANCER_ASSOCIATED_READER \
  capset:pathmnist_cancer_associated_reader \
  query_model_cancer_associated_reader \
  "${ECT_B}"

section "4. Gatekeeper ALLOW/DENY matrix and backend execution"

call_predict \
  "Audrey requests lymphocytes" \
  Audrey "${ECT_A}" Audrey lymphocytes true

call_predict \
  "Audrey requests colorectal_adenocarcinoma_epithelium" \
  Audrey "${ECT_A}" Audrey colorectal_adenocarcinoma_epithelium false capability_scope_exceeded

call_predict \
  "Bob requests colorectal_adenocarcinoma_epithelium" \
  Bob "${ECT_B}" Bob colorectal_adenocarcinoma_epithelium true

call_predict \
  "Bob requests lymphocytes" \
  Bob "${ECT_B}" Bob lymphocytes false capability_scope_exceeded

call_predict \
  "Audrey requests reserved background" \
  Audrey "${ECT_A}" Audrey background false reserved_tissue

call_predict \
  "Audrey ECT is presented with Bob's DPoP" \
  Audrey "${ECT_A}" Bob lymphocytes false dpop_binding_mismatch

section "5. Evidence summary"

printf '%-8s %-8s %-38s %-6s %-28s %-9s %s\n' \
  "ECT" "DPoP" "REQUESTED TISSUE" "ALLOW" "REASON" "EXECUTED" "PREDICTION"
printf '%s\n' \
  "------------------------------------------------------------------------------------------------------------------------"

for row in "${SUMMARY_ROWS[@]}"; do
  IFS='|' read -r holder signer tissue allow reason executed predicted <<<"${row}"
  printf '%-8s %-8s %-38s %-6s %-28s %-9s %s\n' \
    "${holder}" "${signer}" "${tissue}" "${allow}" "${reason}" "${executed}" "${predicted}"
done

echo
pass "Test3A evidence chain completed successfully"

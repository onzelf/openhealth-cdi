#!/usr/bin/env bash
set -euo pipefail

# PathMNIST FCaC admission microbenchmark.
#
# Measures the Gatekeeper /admission/check path only. ECT minting and DPoP
# construction happen outside the measured server-side admission interval.
#
# Usage:
#   ./Bench_admission.sh <active-envelope-id>
#
# Cases:
#   BENCH_CASE=allow       -> mucus, expected ALLOW
#   BENCH_CASE=deny_scope  -> background, expected capability_scope_exceeded
#   BENCH_CASE=deny_pop    -> mucus with wrong holder key, expected dpop_binding_mismatch
#   BENCH_CASE=deny_reserved -> debris, expected reserved_tissue
#
# Examples:
#   BENCH_CASE=allow      NITER=1000 ./Bench_admission.sh <envelope-id>
#   BENCH_CASE=deny_scope NITER=1000 ./Bench_admission.sh <envelope-id>
#   BENCH_CASE=deny_pop   NITER=1000 ./Bench_admission.sh <envelope-id>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOLS_DIR="${SRC_DIR}/tools"

VERIFIER_HOST="${VERIFIER_HOST:-verifier.local}"
VERIFIER_PORT="${VERIFIER_PORT:-8443}"
VERIFIER_URL="${VERIFIER_URL:-https://${VERIFIER_HOST}:${VERIFIER_PORT}}"
ADMISSION_URL="${VERIFIER_URL}/admission/check"
DPoP_HTU="${DPoP_HTU:-https://verifier.local/admission/check}"

CACERT="${CACERT:-${SRC_DIR}/vfp-governance/verifier/certs/ca.crt}"
HUB_CRT="${HUB_CRT:-${SRC_DIR}/vfp-governance/verifier/certs/hub.crt}"
HUB_KEY="${HUB_KEY:-${SRC_DIR}/vfp-governance/verifier/certs/hub.key}"
MINT_CRT="${MINT_CRT:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt}"
MINT_KEY="${MINT_KEY:-${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key}"

MAKE_DPOP="${MAKE_DPOP:-${TOOLS_DIR}/make_dpop_jwt_eddsa.py}"
GEN_MEMBER_KEYS="${GEN_MEMBER_KEYS:-${TOOLS_DIR}/gen_member_keys.py}"
POLICY_JSON="${POLICY_JSON:-${SRC_DIR}/vfp-governance/verifier/state/policy.json}"

ENVELOPE_ID="${1:-}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
BENCH_CASE="${BENCH_CASE:-allow}"
NITER="${NITER:-1000}"
SLEEP_MS="${SLEEP_MS:-0}"

CAP_PROFILE="${CAP_PROFILE:-capset:pathmnist_other_tissue_reader}"
BENCH_SUB="${BENCH_SUB:-Martinez}"
ACTOR_TYPE="${ACTOR_TYPE:-human}"
RESOURCE="pathmnist-colon-pathology"
ACTION="query_model"
PURPOSE="approved_model_query"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass() {
  printf '\033[32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

require_file() {
  [[ -s "$1" ]] || fail "Missing or empty file: $1"
}

ms_sleep() {
  local ms="$1"
  [[ "$ms" -le 0 ]] && return 0
  python3 - "$ms" <<'PY'
import sys, time
time.sleep(int(sys.argv[1]) / 1000.0)
PY
}

[[ -n "${ENVELOPE_ID}" ]] || fail "Usage: $0 <active-envelope-id>"

for cmd in curl jq python3 docker; do
  need "$cmd"
done

for path in \
  "$CACERT" \
  "$HUB_CRT" \
  "$HUB_KEY" \
  "$MINT_CRT" \
  "$MINT_KEY" \
  "$MAKE_DPOP" \
  "$GEN_MEMBER_KEYS" \
  "$POLICY_JSON"; do
  require_file "$path"
done

case "$BENCH_CASE" in
  allow)
    REQUESTED_TISSUES='["mucus"]'
    EXPECT_ALLOW="true"
    EXPECT_REASON=""
    OUTPUT_TAG="allow"
    USE_BAD_HOLDER="false"
    ;;
  deny_scope)
    REQUESTED_TISSUES='["background"]'
    EXPECT_ALLOW="false"
    EXPECT_REASON="capability_scope_exceeded"
    OUTPUT_TAG="deny_scope"
    USE_BAD_HOLDER="false"
    ;;
  deny_pop)
    REQUESTED_TISSUES='["mucus"]'
    EXPECT_ALLOW="false"
    EXPECT_REASON="dpop_binding_mismatch"
    OUTPUT_TAG="deny_pop"
    USE_BAD_HOLDER="true"
    ;;
  deny_reserved)
    REQUESTED_TISSUES='["debris"]'
    EXPECT_ALLOW="false"
    EXPECT_REASON="reserved_tissue"
    OUTPUT_TAG="deny_reserved"
    USE_BAD_HOLDER="false"
    ;;
  *)
    fail "Unknown BENCH_CASE=${BENCH_CASE}; expected allow, deny_scope, deny_pop, or deny_reserved"
    ;;
esac

# Fail fast if the benchmark assumptions no longer match the executable policy.
jq -e \
  --arg profile "$CAP_PROFILE" \
  '.cap_profiles[$profile].cap | type == "array" and length > 0' \
  "$POLICY_JSON" >/dev/null || fail "Missing policy capset: ${CAP_PROFILE}"

OP_ID="$(jq -r --arg profile "$CAP_PROFILE" '.cap_profiles[$profile].cap[0]' "$POLICY_JSON")"

jq -e \
  --arg op "$OP_ID" \
  '.ops[$op].resource == "pathmnist-colon-pathology"
   and .ops[$op].action == "query_model"
   and .ops[$op].purpose == "approved_model_query"
   and (.ops[$op].scope.pathology_labels | index("mucus") != null)
   and (.ops[$op].scope.pathology_labels | index("background") == null)
   and (.caveats.reserved_pathology_labels | index("debris") != null)' \
  "$POLICY_JSON" >/dev/null || fail "Benchmark assumptions do not match current PathMNIST policy"

CURL_HUB=(
  -sS
  --cacert "$CACERT"
  --cert "$HUB_CRT"
  --key "$HUB_KEY"
)

CURL_MINT=(
  -sS
  --cacert "$CACERT"
  --cert "$MINT_CRT"
  --key "$MINT_KEY"
)

STATUS="$(curl "${CURL_HUB[@]}" "${VERIFIER_URL}/status?state=ACTIVE")"
printf '%s\n' "$STATUS" | jq -e \
  --arg envelope "$ENVELOPE_ID" \
  '.envelopes[] | select(.envelope_id == $envelope and .state == "ACTIVE")' \
  >/dev/null || fail "Envelope is absent or not ACTIVE: ${ENVELOPE_ID}"

python3 "$GEN_MEMBER_KEYS" \
  --org "org://HospitalA" \
  --who "$BENCH_SUB" \
  --output-dir "$TMP_DIR" \
  >/dev/null

python3 "$GEN_MEMBER_KEYS" \
  --org "org://HospitalA" \
  --who "${BENCH_SUB}-intruder" \
  --output-dir "$TMP_DIR" \
  >/dev/null

GOOD_PRIV="$(tr -d '\r\n' < "${TMP_DIR}/${BENCH_SUB}.privhex")"
GOOD_PUB="$(tr -d '\r\n' < "${TMP_DIR}/${BENCH_SUB}.pubb64")"
BAD_PRIV="$(tr -d '\r\n' < "${TMP_DIR}/${BENCH_SUB}-intruder.privhex")"
BAD_PUB="$(tr -d '\r\n' < "${TMP_DIR}/${BENCH_SUB}-intruder.pubb64")"

NBF="$(date -u -Iseconds -d '-60 seconds' | sed 's/+00:00/Z/')"
EXP="$(date -u -Iseconds -d '+30 minutes' | sed 's/+00:00/Z/')"

MINT_REQUEST="$(jq -nc \
  --arg pub "$GOOD_PUB" \
  --arg profile "$CAP_PROFILE" \
  --arg envelope "$ENVELOPE_ID" \
  --arg sub "$BENCH_SUB" \
  --arg actor_type "$ACTOR_TYPE" \
  --arg nbf "$NBF" \
  --arg exp "$EXP" \
  '{
    holder_pub_b64: $pub,
    cap_profiles: [$profile],
    envelope_id: $envelope,
    sub: $sub,
    actor_type: $actor_type,
    nbf: $nbf,
    exp: $exp
  }')"

MINT_RESPONSE="$(curl "${CURL_MINT[@]}" \
  -X POST "${VERIFIER_URL}/mint_ect" \
  -H 'content-type: application/json' \
  -d "$MINT_REQUEST")"

ECT="$(printf '%s' "$MINT_RESPONSE" | jq -r '.ect_jws // empty')"
[[ -n "$ECT" ]] || {
  printf '%s\n' "$MINT_RESPONSE" | jq . >&2 || true
  fail "Direct /mint_ect did not return ect_jws"
}

make_dpop() {
  local priv_hex="$1"
  local pub_b64="$2"
  local nonce="$3"
  local jti="$4"

  python3 "$MAKE_DPOP" \
    "$priv_hex" \
    "$pub_b64" \
    "$nonce" \
    "$jti" \
    "POST" \
    "$DPoP_HTU" \
    "$ENVELOPE_ID"
}

make_body() {
  local jti="$1"
  jq -nc \
    --arg envelope "$ENVELOPE_ID" \
    --arg run "$RUN_ID" \
    --arg resource "$RESOURCE" \
    --arg action "$ACTION" \
    --arg purpose "$PURPOSE" \
    --arg jti "$jti" \
    --argjson tissues "$REQUESTED_TISSUES" \
    '{
      envelope_id: $envelope,
      run_id: $run,
      resource: $resource,
      action: $action,
      purpose: $purpose,
      requested_tissues: $tissues,
      jti: $jti
    }'
}

run_one() {
  local sequence="$1"
  local nonce="bench-nonce-$(date +%s%N)-${sequence}"
  local jti="bench-jti-$(date +%s%N)-${sequence}"
  local priv="$GOOD_PRIV"
  local pub="$GOOD_PUB"

  if [[ "$USE_BAD_HOLDER" == "true" ]]; then
    priv="$BAD_PRIV"
    pub="$BAD_PUB"
  fi

  local dpop
  local body
  dpop="$(make_dpop "$priv" "$pub" "$nonce" "$jti")"
  body="$(make_body "$jti")"

  curl "${CURL_HUB[@]}" \
    -X POST "$ADMISSION_URL" \
    -H "Authorization: ECT ${ECT}" \
    -H "DPoP: ${dpop}" \
    -H "X-DPoP-Nonce: ${nonce}" \
    -H 'content-type: application/json' \
    -d "$body"
}

printf '== Preflight: case=%s envelope=%s ==\n' "$BENCH_CASE" "$ENVELOPE_ID"
PREFLIGHT="$(run_one preflight)"
printf '%s\n' "$PREFLIGHT" | jq .

ACTUAL_ALLOW="$(printf '%s' "$PREFLIGHT" | jq -r '.allow')"
ACTUAL_REASON="$(printf '%s' "$PREFLIGHT" | jq -r '.reason // ""')"
[[ "$ACTUAL_ALLOW" == "$EXPECT_ALLOW" ]] || fail \
  "Preflight expected allow=${EXPECT_ALLOW}, got ${ACTUAL_ALLOW}"
[[ "$ACTUAL_REASON" == "$EXPECT_REASON" ]] || fail \
  "Preflight expected reason=${EXPECT_REASON:-<empty>}, got ${ACTUAL_REASON:-<empty>}"
pass "Preflight produced expected governed result"

# Exclude preflight and any stale samples/files from the measured run.
curl "${CURL_HUB[@]}" -X POST "${VERIFIER_URL}/bench/reset" | jq .
docker exec verifier-app sh -lc 'rm -f "${BENCH_OUT:-/tmp/admission_bench.jsonl}"'

echo "== Run N=${NITER} case=${BENCH_CASE} =="
for i in $(seq 1 "$NITER"); do
  run_one "$i" >/dev/null

  PCT=$((i * 100 / NITER))
  FILLED=$((PCT / 2))
  BAR=""
  if (( FILLED > 0 )); then
    BAR="$(printf '%*s' "$FILLED" '' | tr ' ' '#')"
  fi
  printf '\r[%-50s] %d%%' "$BAR" "$PCT"

  ms_sleep "$SLEEP_MS"
done
printf '\n'

FLUSH_JSON="$(curl "${CURL_HUB[@]}" -X POST "${VERIFIER_URL}/bench/flush")"
printf '%s\n' "$FLUSH_JSON" | jq .

FLUSHED="$(printf '%s' "$FLUSH_JSON" | jq -r '.flushed // 0')"
BENCH_PATH="$(printf '%s' "$FLUSH_JSON" | jq -r '.path // empty')"
[[ "$FLUSHED" -eq "$NITER" ]] || fail \
  "Expected ${NITER} benchmark samples, flushed ${FLUSHED}. Is BENCH=1 enabled?"
[[ -n "$BENCH_PATH" ]] || fail "Benchmark flush did not report an output path"

OUTPUT_FILE="${SCRIPT_DIR}/admission_bench_${OUTPUT_TAG}.jsonl"
docker cp "verifier-app:${BENCH_PATH}" "$OUTPUT_FILE" >/dev/null

LINES="$(wc -l < "$OUTPUT_FILE")"
[[ "$LINES" -eq "$NITER" ]] || fail \
  "Expected ${NITER} lines in ${OUTPUT_FILE}, found ${LINES}"

pass "Saved ${OUTPUT_FILE} (${LINES} samples)"
echo "Done."

#!/usr/bin/env bash
# TestC1_minimal_statistics_v2.sh
#
# Relation-authoritative C1 audit.
#
# Security question:
#   Can a controlled Hal select an action that the Hub did not offer and cause
#   the unchanged Hub to execute a hidden representation path anyway?
#
# Stronger reproduction than the original C1:
#   1. Records the exact action set offered by Hub.
#   2. Uses an unknown-action control to prove the Hub does not merely accept
#      every arbitrary action string.
#   3. Forces the exact hidden action minimal_statistics.
#   4. Requires source admission to be DENY while statistics are still returned.
#   5. Verifies bounded inference admission/execution through Hub events.
#   6. Verifies that no unbind or derivative-release admission occurs for the
#      returned minimal_statistics representation.
#
# Verdict contract:
#   rc=0  C1 NOT CONFIRMED / attack rejected
#   rc=1  C1 CONFIRMED / vulnerability reproduced
#   rc=70 harness/precondition error; no security verdict
#
# Usage:
#   ./TestC1_minimal_statistics_v2.sh <active-envelope-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
    echo "Usage: $0 <active-envelope-id>" >&2
    exit 70
}

HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"
ISSUER_IP="${ISSUER_IP:-127.0.0.1}"
ISSUER_PORT="${ISSUER_PORT:-9443}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"

REQUESTER="${REQUESTER:-Audrey}"
TISSUE="${TISSUE:-colorectal_adenocarcinoma_epithelium}"

HAL_CONTAINER="hal"
ORIGINAL_HAL_CONTAINER="hal-c1-original"
HAL_TEST_DOUBLE="${SCRIPT_DIR}/c1_hal_test_double.py"

CA="${SRC_DIR}/vfp-governance/verifier/certs/ca.crt"
A_CRT="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.crt"
A_KEY="${SRC_DIR}/vfp-governance/verifier/certs/HospitalA-admin.key"

REQUESTER_PRIVATE="${REQUESTER_PRIVATE:-${SRC_DIR}/../secrets/holder_keys/${REQUESTER}.privhex}"
GEN_MEMBER_KEYS="${SRC_DIR}/tools/gen_member_keys.py"
MAKE_DPOP="${SRC_DIR}/tools/make_dpop_jwt_eddsa.py"
MINT_PROOF_HTU="${MINT_PROOF_HTU:-urn:openhealth:issuer:mint}"
DPOP_HTU="${DPOP_HTU:-https://verifier.local/admission/check}"

TMP="$(mktemp -d)"

ORIGINAL_STOPPED=0
ORIGINAL_RENAMED=0
STUB_STARTED=0

ok() {
    printf '\033[32m✓\033[0m %s\n' "$*"
}

error() {
    printf '\033[33m! C1 HARNESS ERROR\033[0m %s\n' "$*" >&2
    exit 70
}

protected() {
    printf '\n\033[32mC1 NOT CONFIRMED / PROTECTED\033[0m\n'
    printf '%s\n' "$*"
    exit 0
}

confirmed() {
    printf '\n\033[31mC1 CONFIRMED\033[0m\n'
    printf '%s\n' "$*"
    exit 1
}

section() {
    printf '\n============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

cleanup() {
    set +e

    if [[ "${STUB_STARTED}" == "1" ]]; then
        docker rm -f "${HAL_CONTAINER}" >/dev/null 2>&1
    fi

    if [[ "${ORIGINAL_RENAMED}" == "1" ]]; then
        docker rename \
            "${ORIGINAL_HAL_CONTAINER}" \
            "${HAL_CONTAINER}" \
            >/dev/null 2>&1
    fi

    if [[ "${ORIGINAL_STOPPED}" == "1" ]]; then
        docker start "${HAL_CONTAINER}" >/dev/null 2>&1
    fi

    rm -rf "${TMP}"
}

trap cleanup EXIT

for cmd in curl jq docker grep python3; do
    command -v "${cmd}" >/dev/null 2>&1 ||
        error "Missing command: ${cmd}"
done

for file in "${CA}" "${A_CRT}" "${A_KEY}" "${HAL_TEST_DOUBLE}" \
            "${REQUESTER_PRIVATE}" "${GEN_MEMBER_KEYS}" "${MAKE_DPOP}"; do
    [[ -s "${file}" ]] || error "Missing file: ${file}"
done

REQUESTER_IDENTITY="$(
    python3 "${GEN_MEMBER_KEYS}" \
        --derive \
        --private-key "${REQUESTER_PRIVATE}" \
        --format json
)" || error "Cannot derive ${REQUESTER} holder identity"

REQUESTER_PUB_B64="$(jq -er '.pub_b64' <<<"${REQUESTER_IDENTITY}")" ||
    error "Cannot derive ${REQUESTER} holder public key"

REQUESTER_PRIV_HEX="$(tr -d '\r\n' <"${REQUESTER_PRIVATE}")"
[[ -n "${REQUESTER_PRIV_HEX}" ]] ||
    error "Cannot read ${REQUESTER} holder private key"

REQUESTER_ECT=""

issuer_curl() {
    curl -sS \
        --resolve \
        "issuer-hospitala.local:${ISSUER_PORT}:${ISSUER_IP}" \
        --cacert "${CA}" \
        --cert "${A_CRT}" \
        --key "${A_KEY}" \
        "$@"
}

mint_requester_ect() {
    local nonce jti mint_dpop response

    nonce="c1-mint-nonce-$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(12))
PY
)"
    jti="c1-mint-jti-$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

    mint_dpop="$(
        python3 "${MAKE_DPOP}" \
            "${REQUESTER_PRIV_HEX}" \
            "${REQUESTER_PUB_B64}" \
            "${nonce}" \
            "${jti}" \
            POST \
            "${MINT_PROOF_HTU}" \
            "${ENVELOPE_ID}"
    )" || error "Could not produce ${REQUESTER} holder mint proof"

    response="$(
        issuer_curl \
            -H 'content-type: application/json' \
            -d "$(
                jq -nc \
                    --arg sub "${REQUESTER}" \
                    --arg e "${ENVELOPE_ID}" \
                    --arg dpop "${mint_dpop}" \
                    '{sub:$sub,envelope_id:$e,holder_dpop:$dpop}'
            )" \
            "https://issuer-hospitala.local:${ISSUER_PORT}/mint"
    )" || error "Direct issuer mint failed for ${REQUESTER}"

    REQUESTER_ECT="$(jq -r '.ect // empty' <<<"${response}")"
    [[ -n "${REQUESTER_ECT}" && "${REQUESTER_ECT}" == *.*.* ]] || {
        printf '%s\n' "${response}" | jq . >&2 || true
        error "Issuer returned no compact ECT for ${REQUESTER}"
    }
}

prepare_hal_ect() {
    local response

    response="$(
        docker exec -i fc-hub python - \
            "${ENVELOPE_ID}" \
            "${RUN_ID}" \
            "${TISSUE}" <<'PY'
import json
import sys
import urllib.request

envelope_id, run_id, tissue = sys.argv[1:4]

payload = {
    "principal": "Hal",
    "envelope_id": envelope_id,
    "run_id": run_id,
    "resource": "pathmnist-colon-pathology",
    "action": "bounded_inference",
    "purpose": "bounded_model_inference",
    "requested_tissues": [tissue],
}

req = urllib.request.Request(
    "http://hal:8088/authority/present",
    data=json.dumps(payload).encode("utf-8"),
    headers={"content-type": "application/json"},
    method="POST",
)

with urllib.request.urlopen(req, timeout=15) as r:
    print(r.read().decode("utf-8"))
PY
    )" || error "Hal could not prepare its own authority"

    printf '%s' "${response}" |
        jq -e '
            .principal == "Hal"
            and (.authorization | type == "string")
            and (.authorization | startswith("ECT "))
            and (.dpop | type == "string")
            and (.request.action == "bounded_inference")
        ' >/dev/null || {
            printf '%s
' "${response}" | jq . >&2 || true
            error "Hal authority preparation returned an invalid presentation"
        }

    docker exec "${HAL_CONTAINER}" \
        test -s /var/lib/hal/identity/holder_ect.json ||
        error "Hal did not retain its holder-custodied ECT"
}

set_forced_action() {
    printf '%s\n' "$1" >"${TMP}/forced_action.txt"
    rm -f "${TMP}/hal_decide_request.json"
}

invoke_agent_request() {
    local response_file="$1"
    local nonce jti dpop request_hash

    [[ -n "${REQUESTER_ECT}" ]] ||
        error "${REQUESTER} holder ECT is not prepared"

    nonce="c1-source-nonce-$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(12))
PY
)"
    jti="c1-source-jti-$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

    request_hash="$(
        python3 - \
            "${ENVELOPE_ID}" \
            "${RUN_ID}" \
            "${TISSUE}" <<'PY'
import hashlib
import json
import sys

envelope_id, run_id, tissue = sys.argv[1:]
governed_request = {
    "envelope_id": envelope_id,
    "run_id": run_id,
    "resource": "pathmnist-colon-pathology",
    "action": "query_model",
    "purpose": "approved_model_query",
    "requested_tissues": [tissue],
}
canonical = json.dumps(
    governed_request,
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=False,
).encode("utf-8")
print("sha256:" + hashlib.sha256(canonical).hexdigest())
PY
    )" || error "Could not compute ${REQUESTER} source request_hash"

    dpop="$(
        python3 "${MAKE_DPOP}" \
            "${REQUESTER_PRIV_HEX}" \
            "${REQUESTER_PUB_B64}" \
            "${nonce}" \
            "${jti}" \
            POST \
            "${DPOP_HTU}" \
            "${ENVELOPE_ID}" \
            "${request_hash}"
    )" || error "Could not produce ${REQUESTER} source DPoP"

    curl -sS \
        -o "${response_file}" \
        -w '%{http_code}' \
        -H 'content-type: application/json' \
        -H "Authorization: ECT ${REQUESTER_ECT}" \
        -H "DPoP: ${dpop}" \
        -H "X-DPoP-Nonce: ${nonce}" \
        -d "$(
            jq -nc \
                --arg requester "${REQUESTER}" \
                --arg e "${ENVELOPE_ID}" \
                --arg r "${RUN_ID}" \
                --arg t "${TISSUE}" \
                --arg j "${jti}" '
                {
                    requester:$requester,
                    envelope_id:$e,
                    run_id:$r,
                    requested_tissue:$t,
                    topk:3,
                    jti:$j
                }
                '
        )" \
        "${HUB_URL}/mode1b/agent/request"
}

event_stream() {
    {
        docker exec fc-hub \
            cat "/vault/runs/${RUN_ID}/events.jsonl" \
            2>/dev/null || true
    }
}

event_count() {
    local event_type="$1"

    event_stream |
        jq -s \
            --arg et "${event_type}" \
            --arg e "${ENVELOPE_ID}" \
            --arg t "${TISSUE}" '
            [
                .[]
                | select(.event_type == $et)
                | select(.envelope_id == $e)
                | select((.requested_tissues // []) | index($t) != null)
            ]
            | length
            '
}

latest_event() {
    local event_type="$1"

    event_stream |
        jq -s \
            --arg et "${event_type}" \
            --arg e "${ENVELOPE_ID}" \
            --arg t "${TISSUE}" '
            [
                .[]
                | select(.event_type == $et)
                | select(.envelope_id == $e)
                | select((.requested_tissues // []) | index($t) != null)
            ]
            | last // {}
            '
}

section "1. Verify C1 code path and runtime"

HUB_FILE="${SRC_DIR}/vfp-core/hub/hub.py"

grep -q 'agent_selected_unoffered_action' "${HUB_FILE}" ||
    error "Hub does not contain the unoffered-action guard"

if grep -q 'if action == "minimal_statistics"' "${HUB_FILE}"; then
    error "Hidden minimal_statistics execution branch is still present"
fi

docker inspect fc-hub >/dev/null 2>&1 ||
    error "fc-hub container is unavailable"

docker inspect "${HAL_CONTAINER}" >/dev/null 2>&1 ||
    error "Hal container is unavailable"

BOUNDARY="$(curl -fsS "${HUB_URL}/administration/boundary")"

printf '%s' "${BOUNDARY}" |
    jq -e \
        --arg e "${ENVELOPE_ID}" '
        .selected_envelope_id == $e
        and (
            [.envelopes[]
             | select(
                 .envelope_id == $e
                 and .bound == true
                 and .model_available == true
             )]
            | length == 1
        )
        ' >/dev/null ||
    error "Envelope is not selected, bound, or model-ready"

ok "Selected envelope and model are ready"

section "2. Ensure Hal identity and issuer enrollment"

HAL_JWK="$(
    docker exec "${HAL_CONTAINER}" \
        cat /var/lib/hal/identity/holder.jwk
)"

HAL_JKT="$(
    docker exec "${HAL_CONTAINER}" \
        cat /var/lib/hal/identity/holder.jkt |
        tr -d '\r\n'
)"

HAL_PUB="$(printf '%s' "${HAL_JWK}" | jq -r '.x // empty')"

[[ -n "${HAL_PUB}" && -n "${HAL_JKT}" ]] ||
    error "Hal holder identity is incomplete"

MEMBERS="$(
    issuer_curl \
        "https://issuer-hospitala.local:${ISSUER_PORT}/members"
)"

EXISTING_HAL_JKT="$(
    printf '%s' "${MEMBERS}" |
        jq -r '
            .members[]?
            | select(.sub == "Hal")
            | .jkt
        ' |
        head -n1
)"

if [[ -z "${EXISTING_HAL_JKT}" ]]; then
    REGISTER_BODY="$(
        jq -nc \
            --arg pub "${HAL_PUB}" \
            --arg jkt "${HAL_JKT}" '
            {
                org_id:"org://HospitalA",
                member_id:"hal-mode1b",
                sub:"Hal",
                pub_b64:$pub,
                jkt:$jkt
            }
            '
    )"

    REGISTER_RESPONSE="$(
        issuer_curl \
            -H 'content-type: application/json' \
            -d "${REGISTER_BODY}" \
            "https://issuer-hospitala.local:${ISSUER_PORT}/members/register"
    )"

    printf '%s' "${REGISTER_RESPONSE}" |
        jq -e '.status == "ok"' >/dev/null || {
            printf '%s\n' "${REGISTER_RESPONSE}" | jq . >&2 || true
            error "Hal issuer registration failed"
        }

    ok "Hal enrolled for Mode 1B"
else
    [[ "${EXISTING_HAL_JKT}" == "${HAL_JKT}" ]] ||
        error "Hal issuer JKT differs from persistent holder identity"

    ok "Existing Hal issuer identity matches holder identity"
fi

section "3. Prepare holder and agent credentials"

mint_requester_ect
ok "${REQUESTER} ECT is holder-custodied and ready"

prepare_hal_ect
ok "Hal self-custodied ECT is ready"

section "4. Install controlled Hal test double"

ORIGINAL_HAL_IMAGE="$(
    docker inspect \
        --format '{{.Config.Image}}' \
        "${HAL_CONTAINER}"
)"

[[ -n "${ORIGINAL_HAL_IMAGE}" ]] ||
    error "Cannot determine Hal image"

printf '%s\n' 'refuse' >"${TMP}/forced_action.txt"

docker stop "${HAL_CONTAINER}" >/dev/null
ORIGINAL_STOPPED=1

docker rename \
    "${HAL_CONTAINER}" \
    "${ORIGINAL_HAL_CONTAINER}"
ORIGINAL_RENAMED=1

docker run -d \
    --name "${HAL_CONTAINER}" \
    --network agent-edge \
    -v hal-identity:/var/lib/hal/identity:ro \
    -v "${TMP}:/audit" \
    -v "${HAL_TEST_DOUBLE}:/c1_hal_test_double.py:ro" \
    --entrypoint python \
    "${ORIGINAL_HAL_IMAGE}" \
    /c1_hal_test_double.py \
    >/dev/null

STUB_STARTED=1

for _ in $(seq 1 20); do
    if docker exec fc-hub python - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen(
    "http://hal:8088/health",
    timeout=1,
).read()
PY
    then
        break
    fi
    sleep 1
done

if ! docker exec fc-hub python - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen(
    "http://hal:8088/health",
    timeout=2,
).read()
PY
then
    error "Controlled Hal is not reachable from Hub"
fi

ok "Controlled Hal is reachable through the normal Hub -> Hal aperture"

section "5. Control: an arbitrary unoffered action must not execute"

CONTROL_RESPONSE="${TMP}/control_response.json"
set_forced_action "c1_unknown_action"

CONTROL_BASE_ADMISSION="$(event_count mode1b_bounded_inference_admission)"
CONTROL_BASE_EXECUTION="$(event_count mode1b_bounded_inference_executed)"
CONTROL_BASE_UNBIND="$(event_count mode1b_unbind_admission)"
CONTROL_BASE_RELEASE="$(event_count mode1b_derivative_release_admission)"

CONTROL_STATUS="$(invoke_agent_request "${CONTROL_RESPONSE}")"

[[ -s "${TMP}/hal_decide_request.json" ]] ||
    error "Hub did not invoke Hal /decide during control"

jq -e '
    (.available_actions | type == "array")
    and (.available_actions | index("c1_unknown_action") == null)
    and (.available_actions | index("minimal_statistics") == null)
' "${TMP}/hal_decide_request.json" >/dev/null || {
    jq . "${TMP}/hal_decide_request.json" >&2
    error "Control action unexpectedly appeared in Hub offered actions"
}

if [[ "${CONTROL_STATUS}" != "403" ]]; then
    jq . "${CONTROL_RESPONSE}" >&2 || true
    error "Unknown-action control returned HTTP ${CONTROL_STATUS}; expected 403"
fi

jq -e '.detail == "agent_selected_unoffered_action"' \
    "${CONTROL_RESPONSE}" >/dev/null || {
    jq . "${CONTROL_RESPONSE}" >&2 || true
    error "Unknown-action control was not rejected at offered-action boundary"
}

CONTROL_AFTER_ADMISSION="$(event_count mode1b_bounded_inference_admission)"
CONTROL_AFTER_EXECUTION="$(event_count mode1b_bounded_inference_executed)"
CONTROL_AFTER_UNBIND="$(event_count mode1b_unbind_admission)"
CONTROL_AFTER_RELEASE="$(event_count mode1b_derivative_release_admission)"

(( CONTROL_AFTER_ADMISSION == CONTROL_BASE_ADMISSION )) ||
    error "Unknown action reached bounded-inference admission"

(( CONTROL_AFTER_EXECUTION == CONTROL_BASE_EXECUTION )) ||
    error "Unknown action reached bounded-inference execution"

(( CONTROL_AFTER_UNBIND == CONTROL_BASE_UNBIND )) ||
    error "Unknown action reached unbind admission"

(( CONTROL_AFTER_RELEASE == CONTROL_BASE_RELEASE )) ||
    error "Unknown action reached derivative-release admission"

ok "Arbitrary unoffered action was rejected"
ok "Arbitrary unoffered action caused no downstream execution"

section "6. Capture governance-event baseline"

BASE_ADMISSION="$(event_count mode1b_bounded_inference_admission)"
BASE_EXECUTION="$(event_count mode1b_bounded_inference_executed)"
BASE_UNBIND="$(event_count mode1b_unbind_admission)"
BASE_RELEASE="$(event_count mode1b_derivative_release_admission)"

printf 'bounded_inference_admission=%s\n' "${BASE_ADMISSION}"
printf 'bounded_inference_executed=%s\n' "${BASE_EXECUTION}"
printf 'unbind_admission=%s\n' "${BASE_UNBIND}"
printf 'derivative_release_admission=%s\n' "${BASE_RELEASE}"

section "7. Regression: force the former hidden minimal_statistics action"

EXPLOIT_RESPONSE="${TMP}/exploit_response.json"
set_forced_action "minimal_statistics"

EXPLOIT_STATUS="$(invoke_agent_request "${EXPLOIT_RESPONSE}")"

[[ -s "${TMP}/hal_decide_request.json" ]] ||
    error "Hub did not invoke Hal /decide during regression probe"

jq -e '
    (.available_actions | type == "array")
    and ((.available_actions | sort) == ["blur_image", "refuse"])
    and (.available_actions | index("minimal_statistics") == null)
' "${TMP}/hal_decide_request.json" >/dev/null || {
    jq . "${TMP}/hal_decide_request.json" >&2
    error "Regression precondition failed: offered action set was not exactly blur_image/refuse"
}

ok "Hub offered exactly blur_image/refuse"
ok "minimal_statistics was absent from the offered action set"

if [[ "${EXPLOIT_STATUS}" != "403" ]]; then
    jq . "${EXPLOIT_RESPONSE}" >&2 || true
    error "minimal_statistics returned HTTP ${EXPLOIT_STATUS}; expected 403"
fi

jq -e '
    .detail == "agent_selected_unoffered_action"
    and (has("statistics") | not)
    and (has("prediction") | not)
    and (has("representation") | not)
    and (has("executed") | not)
' "${EXPLOIT_RESPONSE}" >/dev/null || {
    jq . "${EXPLOIT_RESPONSE}" >&2 || true
    error "minimal_statistics rejection leaked execution output"
}

ok "Forced minimal_statistics was rejected at the offered-action boundary"
ok "No prediction-derived information was returned"

section "8. Verify no downstream execution occurred"

AFTER_ADMISSION="$(event_count mode1b_bounded_inference_admission)"
AFTER_EXECUTION="$(event_count mode1b_bounded_inference_executed)"
AFTER_UNBIND="$(event_count mode1b_unbind_admission)"
AFTER_RELEASE="$(event_count mode1b_derivative_release_admission)"

(( AFTER_ADMISSION == BASE_ADMISSION )) ||
    error "Forced minimal_statistics reached bounded-inference admission"

(( AFTER_EXECUTION == BASE_EXECUTION )) ||
    error "Forced minimal_statistics reached bounded-inference execution"

(( AFTER_UNBIND == BASE_UNBIND )) ||
    error "Unexpected unbind admission occurred during minimal_statistics regression"

(( AFTER_RELEASE == BASE_RELEASE )) ||
    error "Unexpected derivative-release admission occurred during minimal_statistics regression"

ok "No bounded-inference admission occurred"
ok "No bounded-inference execution occurred"
ok "No unbind admission was added"
ok "No derivative-release admission was added"

section "9. Evidence"

printf 'Offered actions:\n'
jq '{available_actions}' "${TMP}/hal_decide_request.json"

printf '\nRegression response:\n'
jq . "${EXPLOIT_RESPONSE}"

printf '\nEvent deltas:\n'
printf 'bounded_inference_admission: %s -> %s\n' \
    "${BASE_ADMISSION}" "${AFTER_ADMISSION}"
printf 'bounded_inference_executed:  %s -> %s\n' \
    "${BASE_EXECUTION}" "${AFTER_EXECUTION}"
printf 'unbind_admission:            %s -> %s\n' \
    "${BASE_UNBIND}" "${AFTER_UNBIND}"
printf 'derivative_release_admission:%s -> %s\n' \
    "${BASE_RELEASE}" "${AFTER_RELEASE}"

protected \
    "The Hub rejected unoffered minimal_statistics before bounded inference; no prediction-derived information or downstream governance events were produced."

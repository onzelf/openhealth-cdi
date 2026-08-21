#!/usr/bin/env bash

set -euo pipefail

pass() {
  printf '\033[32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[31m✗\033[0m %s\n' "$*" >&2
  exit 1
}

ENVELOPE_ID="${1:-}"

[[ -n "${ENVELOPE_ID}" ]] ||
    fail "Usage: $0 <active-envelope-id>"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

API_URL="${API_URL:-http://127.0.0.1:8082/api}"
PRINCIPAL="${PRINCIPAL:-Audrey}"

HUB_FILE="${SRC_DIR}/vfp-core/hub/hub.py"
FRONTEND_FILE="${SRC_DIR}/vfp-core/frontend/src/App.jsx"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT


pass() {
    printf '\033[32m✓\033[0m %s\n' "$*"
}


fail() {
    printf '\033[31m✗\033[0m %s\n' "$*" >&2
    exit 1
}


section() {
    printf '\n\033[1m== %s ==\033[0m\n' "$*"
}


require_command() {
    local command_name="$1"

    command -v "${command_name}" >/dev/null 2>&1 ||
        fail "Missing command: ${command_name}"
}


require_file() {
    local path="$1"

    [[ -s "${path}" ]] ||
        fail "Missing or empty file: ${path}"
}


for command_name in curl jq grep; do
    require_command "${command_name}"
done

require_file "${HUB_FILE}"
require_file "${FRONTEND_FILE}"


section "1. Static policy-duplication check"

if grep -nE \
    'PROFILE_TISSUE_HINTS|allowed_tissues' \
    "${HUB_FILE}" \
    "${FRONTEND_FILE}"; then

    fail "Hub or frontend still contains duplicated tissue authorization"
fi

pass "No duplicated tissue authorization remains in Hub or frontend"


section "2. Frontend API availability"

BOUNDARY_RESPONSE="$(
    curl -fsS "${API_URL}/administration/boundary"
)" || fail "Frontend API proxy is unavailable: ${API_URL}"

printf '%s\n' "${BOUNDARY_RESPONSE}" |
    jq . >"${TMP_DIR}/boundary.json"

jq -e \
    '[.. | objects | select(has("allowed_tissues"))] | length == 0' \
    "${TMP_DIR}/boundary.json" >/dev/null ||
    fail "Administration response still publishes allowed_tissues"

pass "Administration API does not publish allowed_tissues"


section "3. Legacy options endpoint"

OPTIONS_FILE="${TMP_DIR}/options.json"

OPTIONS_STATUS="$(
    curl \
        -sS \
        -o "${OPTIONS_FILE}" \
        -w '%{http_code}' \
        "${API_URL}/predictions/ab/options"
)"

case "${OPTIONS_STATUS}" in
    200)
        jq -e \
            '[.. | objects | select(has("allowed_tissues"))] | length == 0' \
            "${OPTIONS_FILE}" >/dev/null ||
            fail "Legacy options endpoint still publishes allowed_tissues"

        pass "Legacy options endpoint contains no allowed_tissues"
        ;;

    404)
        pass "Legacy options endpoint has been removed"
        ;;

    *)
        cat "${OPTIONS_FILE}" >&2
        fail "Unexpected options endpoint status: ${OPTIONS_STATUS}"
        ;;
esac

##########################################################################
section "4. Select and verify envelope"

SELECT_FILE="${TMP_DIR}/select-envelope.json"

SELECT_STATUS="$(
    curl \
        -sS \
        -o "${SELECT_FILE}" \
        -w '%{http_code}' \
        -X POST \
        "${API_URL}/administration/envelopes/${ENVELOPE_ID}/select"
)"

if [[ "${SELECT_STATUS}" != "200" ]]; then
    cat "${SELECT_FILE}" >&2
    fail "Envelope selection failed with HTTP ${SELECT_STATUS}"
fi

pass "Envelope selected: ${ENVELOPE_ID}"

BOUNDARY_RESPONSE="$(
    curl -fsS "${API_URL}/administration/boundary"
)" || fail "Could not refresh administration boundary"

printf '%s\n' "${BOUNDARY_RESPONSE}" |
    jq . >"${TMP_DIR}/boundary.json"

SELECTED_ENVELOPE_ID="$(
    jq -r '.selected_envelope_id // empty' \
        "${TMP_DIR}/boundary.json"
)"

[[ "${SELECTED_ENVELOPE_ID}" == "${ENVELOPE_ID}" ]] ||
    fail \
        "Selected envelope is ${SELECTED_ENVELOPE_ID:-none}, expected ${ENVELOPE_ID}"

BOUND="$(
    jq -r \
        --arg envelope "${ENVELOPE_ID}" \
        '
        .envelopes[]
        | select(.envelope_id == $envelope)
        | .bound
        ' \
        "${TMP_DIR}/boundary.json"
)"

[[ "${BOUND}" == "true" ]] ||
    fail "Envelope is selected but not bound: ${ENVELOPE_ID}"

pass "Envelope is selected and bound"


#####################################################################
section "5. Ensure Audrey has a current ECT"

ECT_STATUS="$(
    jq -r \
        --arg principal "${PRINCIPAL}" \
        '
        .holders[]
        | select(.principal == $principal)
        | .ect_status
        ' \
        "${TMP_DIR}/boundary.json"
)"

[[ -n "${ECT_STATUS}" ]] ||
    fail "Principal is absent from boundary state: ${PRINCIPAL}"

if [[ "${ECT_STATUS}" != "ready" ]]; then
    MINT_FILE="${TMP_DIR}/mint.json"

    MINT_STATUS="$(
        curl \
            -sS \
            -o "${MINT_FILE}" \
            -w '%{http_code}' \
            -X POST \
            "${API_URL}/administration/holders/${PRINCIPAL}/mint-ect" \
            -H 'content-type: application/json' \
            -d "$(
                jq -nc \
                    --arg envelope "${ENVELOPE_ID}" \
                    '{envelope_id: $envelope}'
            )"
    )"

    if [[ "${MINT_STATUS}" != "200" ]]; then
        cat "${MINT_FILE}" >&2
        fail "ECT minting failed with HTTP ${MINT_STATUS}"
    fi

    jq . "${MINT_FILE}"
    pass "Fresh ECT minted for ${PRINCIPAL}"
else
    pass "Current ECT is already ready for ${PRINCIPAL}"
fi


run_case() {
    local tissue="$1"
    local expected_allow="$2"
    local expected_reason="$3"

    local response_file="${TMP_DIR}/${tissue}.json"
    local status
    local actual_allow
    local actual_reason
    local executed

    status="$(
        curl \
            -sS \
            -o "${response_file}" \
            -w '%{http_code}' \
            -X POST \
            "${API_URL}/user/inference" \
            -H 'content-type: application/json' \
            -d "$(
                jq -nc \
                    --arg principal "${PRINCIPAL}" \
                    --arg envelope "${ENVELOPE_ID}" \
                    --arg tissue "${tissue}" \
                    '{
                        principal: $principal,
                        envelope_id: $envelope,
                        requested_tissue: $tissue,
                        topk: 3
                    }'
            )"
    )"

    if [[ "${status}" != "200" ]]; then
        cat "${response_file}" >&2
        fail "${tissue} returned HTTP ${status}"
    fi

    actual_allow="$(
        jq -r '.admission.allow' "${response_file}"
    )"

    actual_reason="$(
        jq -r '.admission.reason // ""' "${response_file}"
    )"

    executed="$(
        jq -r '.executed' "${response_file}"
    )"

    [[ "${actual_allow}" == "${expected_allow}" ]] ||
        fail \
            "${tissue} expected allow=${expected_allow}, got ${actual_allow}"

    if [[ -n "${expected_reason}" ]]; then
        [[ "${actual_reason}" == "${expected_reason}" ]] ||
            fail \
                "${tissue} expected reason=${expected_reason}, got ${actual_reason}"
    fi

    if [[ "${expected_allow}" == "true" ]]; then
        [[ "${executed}" == "true" ]] ||
            fail "${tissue} was admitted but inference was not executed"
    else
        [[ "${executed}" == "false" ]] ||
            fail "${tissue} was denied but inference was executed"
    fi

    printf '\n%s\n' "${tissue}"
    jq '{
        request,
        admission,
        executed,
        model_run_id
    }' "${response_file}"

    pass "${tissue} produced the expected governed result"
}


#################################################################################
section "6. Governed inference behavior"

run_case \
    "mucus" \
    "true" \
    ""

run_case \
    "debris" \
    "false" \
    "capability_scope_exceeded"

run_case \
    "cancer_associated_stroma" \
    "false" \
    "capability_scope_exceeded"

run_case \
    "background" \
    "false" \
    "reserved_tissue"


printf '\n'
pass "Dashboard policy-scope test passed"
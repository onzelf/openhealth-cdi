#!/usr/bin/env bash
set -euo pipefail

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
    printf 'Usage: %s <active-envelope-id>\n' "$0" >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"
PRINCIPAL="${PRINCIPAL:-Charlie}"
DECISIONS_DIR="${SRC_DIR}/vfp-governance/verifier/state/events/decisions"
MODEL_EVIDENCE="${SRC_DIR}/vfp-governance/verifier/vault/${ENVELOPE_ID}/run.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass() { printf '\033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

for command_name in curl jq; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        fail "Missing command: ${command_name}"
done

[[ -s "${MODEL_EVIDENCE}" ]] ||
    fail "Missing envelope model evidence: ${MODEL_EVIDENCE}"

ALL_TISSUES='[
  "adipose",
  "debris",
  "lymphocytes",
  "mucus",
  "smooth_muscle",
  "normal_colon_mucosa",
  "cancer_associated_stroma",
  "colorectal_adenocarcinoma_epithelium"
]'

section "1. Gate 3A credential and A+B model remain present"

BOUNDARY_FILE="${TMP_DIR}/boundary.json"
curl -fsS "${HUB_URL}/administration/boundary" | jq . >"${BOUNDARY_FILE}"

SELECTED_ENVELOPE="$(jq -r '.selected_envelope_id // empty' "${BOUNDARY_FILE}")"
[[ "${SELECTED_ENVELOPE}" == "${ENVELOPE_ID}" ]] ||
    fail "Selected envelope is ${SELECTED_ENVELOPE:-none}, expected ${ENVELOPE_ID}"

CHARLIE_ECT_STATUS="$(
    jq -r \
        --arg principal "${PRINCIPAL}" \
        '.holders[] | select(.principal == $principal) | .ect_status' \
        "${BOUNDARY_FILE}"
)"
[[ "${CHARLIE_ECT_STATUS}" == "ready" ]] ||
    fail "Charlie ECT is ${CHARLIE_ECT_STATUS:-missing}; run Test3F first"

MODEL_BEFORE="$(jq -r '.run_id // empty' "${MODEL_EVIDENCE}")"
[[ -n "${MODEL_BEFORE}" ]] ||
    fail "Envelope run.json does not contain run_id"

pass "Charlie ECT is ready; E2 model pointer is ${MODEL_BEFORE}"

section "2. Full non-reserved guest partition is ALLOW"

ALLOW_FILE="${TMP_DIR}/guest-allow.json"
ALLOW_STATUS="$(
    curl -sS -o "${ALLOW_FILE}" -w '%{http_code}' \
        -X POST "${HUB_URL}/mode1a/guest/contribution/admission" \
        -H 'content-type: application/json' \
        -d "$(
            jq -nc \
                --arg principal "${PRINCIPAL}" \
                --arg envelope "${ENVELOPE_ID}" \
                --argjson tissues "${ALL_TISSUES}" \
                '{
                    principal: $principal,
                    envelope_id: $envelope,
                    requested_tissues: $tissues
                }'
        )"
)"

[[ "${ALLOW_STATUS}" == "200" ]] || {
    cat "${ALLOW_FILE}" >&2
    fail "Guest contribution admission returned HTTP ${ALLOW_STATUS}"
}

jq . "${ALLOW_FILE}"

jq -e '.admission.allow == true and .executed == false' "${ALLOW_FILE}" >/dev/null ||
    fail "Charlie guest contribution was not ALLOW without execution"

ALLOW_DECISION_ID="$(jq -r '.admission.decision_id // empty' "${ALLOW_FILE}")"
[[ -n "${ALLOW_DECISION_ID}" ]] || fail "ALLOW decision_id is missing"

ALLOW_RECORD="${DECISIONS_DIR}/${ALLOW_DECISION_ID}.json"
[[ -s "${ALLOW_RECORD}" ]] || fail "Missing signed ALLOW evidence"

jq -e \
    --arg principal "${PRINCIPAL}" \
    --arg envelope "${ENVELOPE_ID}" \
    '
    .artifact_type == "fcac_admission_decision"
    and .allow_or_deny == "ALLOW"
    and .sub == $principal
    and .approved_research_collaboration == $envelope
    and .requested_action == "submit_update"
    and .requested_purpose == "federated_training"
    and (.cap_profiles | index("capset:pathmnist_guest_contributor") != null)
    and (.cap_profiles | index("capset:pathmnist_other_tissue_reader") == null)
    and (.cap_profiles | index("capset:pathmnist_cancer_associated_reader") == null)
    and .related_model_run_when_applicable == null
    ' \
    "${ALLOW_RECORD}" >/dev/null ||
    fail "Signed ALLOW evidence does not describe the narrow guest capability"

ALLOW_ECT_HASH="$(jq -r '.presented_ect_sha256 // empty' "${ALLOW_RECORD}")"
[[ -n "${ALLOW_ECT_HASH}" ]] || fail "ALLOW evidence lacks ECT fingerprint"

pass "Charlie passed only through the guest contribution aperture"

section "3. Same ECT cannot contribute reserved tissue background"

DENY_FILE="${TMP_DIR}/guest-deny-background.json"
DENY_STATUS="$(
    curl -sS -o "${DENY_FILE}" -w '%{http_code}' \
        -X POST "${HUB_URL}/mode1a/guest/contribution/admission" \
        -H 'content-type: application/json' \
        -d "$(
            jq -nc \
                --arg principal "${PRINCIPAL}" \
                --arg envelope "${ENVELOPE_ID}" \
                '{
                    principal: $principal,
                    envelope_id: $envelope,
                    requested_tissues: ["background"]
                }'
        )"
)"

[[ "${DENY_STATUS}" == "200" ]] || {
    cat "${DENY_FILE}" >&2
    fail "Reserved-tissue probe returned HTTP ${DENY_STATUS}"
}

jq -e \
    '.admission.allow == false
     and .admission.reason == "reserved_tissue"
     and .executed == false' \
    "${DENY_FILE}" >/dev/null ||
    fail "Background did not produce reserved_tissue DENY"

DENY_DECISION_ID="$(jq -r '.admission.decision_id // empty' "${DENY_FILE}")"
DENY_RECORD="${DECISIONS_DIR}/${DENY_DECISION_ID}.json"
[[ -s "${DENY_RECORD}" ]] || fail "Missing signed Background tissue DENY evidence"

DENY_ECT_HASH="$(jq -r '.presented_ect_sha256 // empty' "${DENY_RECORD}")"
[[ "${DENY_ECT_HASH}" == "${ALLOW_ECT_HASH}" ]] ||
    fail "ALLOW and DENY probes did not present the same Charlie ECT"

pass "Reserved tissue remains closed under the same guest credential"

section "4. Contribution authority does not create query authority"

while IFS= read -r tissue; do
    QUERY_FILE="${TMP_DIR}/query-${tissue}.json"
    QUERY_STATUS="$(
        curl -sS -o "${QUERY_FILE}" -w '%{http_code}' \
            -X POST "${HUB_URL}/user/inference" \
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

    [[ "${QUERY_STATUS}" == "200" ]] || {
        cat "${QUERY_FILE}" >&2
        fail "Query probe ${tissue} returned HTTP ${QUERY_STATUS}"
    }

    jq -e \
        '.admission.allow == false
         and .admission.reason == "capability_violation"
         and .executed == false' \
        "${QUERY_FILE}" >/dev/null ||
        fail "Charlie unexpectedly acquired query authority for ${tissue}"
done < <(jq -r '.[]' <<<"${ALL_TISSUES}")

pass "Charlie cannot query any non-reserved PathMNIST tissue"

section "5. Gate 3B did not move the model"

MODEL_AFTER="$(jq -r '.run_id // empty' "${MODEL_EVIDENCE}")"
[[ "${MODEL_AFTER}" == "${MODEL_BEFORE}" ]] ||
    fail "Model pointer moved from ${MODEL_BEFORE} to ${MODEL_AFTER}"

pass "E2 still points to ${MODEL_AFTER}; no Flower execution occurred"
printf '\n\033[32mPASS\033[0m Gate 3B guest contribution aperture\n'

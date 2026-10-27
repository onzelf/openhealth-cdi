#!/usr/bin/env bash

set -uo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <active-envelope-id>"
    exit 2
fi

ENVELOPE_ID="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TESTS=(
    TestA0_capability_non_amplification.sh
    TestA1_external_surface.sh
    TestA2_cross_org_mint.sh
    TestA3_wrong_role_mint.sh
    TestA4_external_hub_substitution.sh
    TestA5_semantic_request_substitution.sh
    TestA6_issuer_independence.sh
    TestA8_cross_envelope_authority.sh
    TestA9_actor_type_confusion.sh
    TestC1_minimal_statistics.sh
    TestC2_impersonation.sh
)

declare -A RESULTS
declare -A EXIT_CODES

echo
echo "============================================================"
echo " OpenHealth security audit"
echo " Envelope: $ENVELOPE_ID"
echo "============================================================"

for test in "${TESTS[@]}"; do
    echo
    echo "------------------------------------------------------------"
    echo "RUNNING: $test"
    echo "------------------------------------------------------------"

    if [[ ! -f "$test" ]]; then
        echo "? MISSING: $test"
        RESULTS["$test"]="MISSING"
        EXIT_CODES["$test"]="-"
        continue
    fi

    [[ -x "$test" ]] || chmod +x "$test"

    tmp="$(mktemp)"

    set +e
    "./$test" "$ENVELOPE_ID" 2>&1 | tee "$tmp"
    rc=${PIPESTATUS[0]}
    set -e

    EXIT_CODES["$test"]="$rc"

    #
    # The explicit verdict emitted by the audit test is authoritative.
    # Exit status is used only as a fallback for older tests.
    #
    if grep -qiE 'VULNERABILITY[[:space:]]+CONFIRMED|C[0-9]+[[:space:]]+CONFIRMED|CONFIRMED[[:space:]]*$' "$tmp"; then
        RESULTS["$test"]="VULNERABILITY CONFIRMED"

    elif grep -qiE 'ASSUMPTION[[:space:]]+REJECTED|PROTECTED' "$tmp"; then
        RESULTS["$test"]="ASSUMPTION REJECTED / PROTECTED"

    elif grep -qiE 'INCONCLUSIVE' "$tmp"; then
        RESULTS["$test"]="INCONCLUSIVE"

    else
        case "$rc" in
            0)
                RESULTS["$test"]="ASSUMPTION REJECTED "
                ;;
            1)
                RESULTS["$test"]="VULNERABILITY CONFIRMED "
                ;;
            2)
                RESULTS["$test"]="INCONCLUSIVE"
                ;;
            *)
                RESULTS["$test"]="ERROR (exit $rc)"
                ;;
        esac
    fi

    rm -f "$tmp"
done

echo
echo
echo "============================================================"
echo " AUDIT SUMMARY"
echo "============================================================"

for test in "${TESTS[@]}"; do
    printf "%-45s %-34s [rc=%s]\n" \
        "$test" \
        "${RESULTS[$test]}" \
        "${EXIT_CODES[$test]}"
done

echo "============================================================"

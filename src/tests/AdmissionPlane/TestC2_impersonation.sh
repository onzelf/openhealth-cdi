#!/usr/bin/env bash
set -uo pipefail

# C2 — Hal principal impersonation / authority-substitution scenario
#
# C2a — holder identity discovery
# C2b — authority substitution
#
# Exit codes:
#   0   GREEN
#   1   RED
#   2   PARTIAL
#   70  HARNESS ERROR / INCONCLUSIVE

ENVELOPE_ID="${1:-}"

[[ -n "${ENVELOPE_ID}" ]] || {
    echo "Usage: $0 <active-envelope-id>" >&2
    exit 70
}

SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" &&
    pwd
)"

C2A="${SCRIPT_DIR}/TestC2a_holder_identity_disclosure.sh"
C2B="${SCRIPT_DIR}/TestC2b_authority_substitution.sh"

section() {
    printf '\n'
    printf '============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

for test_script in "${C2A}" "${C2B}"; do
    [[ -x "${test_script}" ]] || {
        echo "C2 HARNESS ERROR — missing or non-executable test: ${test_script}" >&2
        exit 70
    }
done

section "C2 — principal impersonation / authority substitution"


section "C2a — holder identity discovery"

"${C2A}" "${ENVELOPE_ID}"
C2A_RC=$?

case "${C2A_RC}" in
    0)
        C2A_RESULT="GREEN"
        ;;
    1)
        C2A_RESULT="RED"
        ;;
    70)
        C2A_RESULT="ERROR"
        ;;
    *)
        C2A_RESULT="ERROR"
        ;;
esac


section "C2b — authority substitution"

"${C2B}" "${ENVELOPE_ID}"
C2B_RC=$?

case "${C2B_RC}" in
    0)
        C2B_RESULT="GREEN"
        ;;
    1)
        C2B_RESULT="RED"
        ;;
    70)
        C2B_RESULT="ERROR"
        ;;
    *)
        C2B_RESULT="ERROR"
        ;;
esac


section "C2 composite result"

printf '%-8s %-10s %s\n' \
    "TEST" "RESULT" "INVARIANT"

printf '%s\n' \
    "---------------------------------------------------------------------"

printf '%-8s %-10s %s\n' \
    "C2a" "${C2A_RESULT}" \
    "Hal cannot enumerate unrelated human holders"

printf '%-8s %-10s %s\n' \
    "C2b" "${C2B_RESULT}" \
    "Knowing a holder identifier cannot confer holder authority"

printf '%s\n' \
    "---------------------------------------------------------------------"


# A harness failure is not a security result.
if [[ "${C2A_RESULT}" == "ERROR" ||
      "${C2B_RESULT}" == "ERROR" ]]; then

    printf '\n'
    printf '! C2 HARNESS ERROR — at least one subtest was inconclusive\n'
    exit 70
fi


# Both security properties hold.
if [[ "${C2A_RESULT}" == "GREEN" &&
      "${C2B_RESULT}" == "GREEN" ]]; then

    printf '\n'
    printf '✓ C2 GREEN — identity enumeration and authority substitution are blocked\n'
    exit 0
fi


# Both security properties fail.
if [[ "${C2A_RESULT}" == "RED" &&
      "${C2B_RESULT}" == "RED" ]]; then

    printf '\n'
    printf '✗ C2 RED — identity enumeration and authority substitution both succeed\n'
    exit 1
fi


# One property fails while the other holds.
printf '\n'

if [[ "${C2A_RESULT}" == "RED" &&
      "${C2B_RESULT}" == "GREEN" ]]; then

    printf '! C2 PARTIAL — holder enumeration succeeds, authority substitution is blocked\n'
    exit 2
fi

printf '! C2 PARTIAL — holder enumeration is blocked, authority substitution succeeds\n'
exit 2 
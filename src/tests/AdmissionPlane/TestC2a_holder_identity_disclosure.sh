#!/usr/bin/env bash
set -euo pipefail

# C2a — holder identity discovery from the Hal trust boundary
#
# Question:
#   Can Hal, starting without knowledge of Audrey/Bob, discover human
#   holder identities through the only federation aperture available to it?
#
# PASS:
#   The Hub aperture does not disclose human principals and does not expose
#   a distinguishable principal-existence oracle.
#
# FAIL:
#   Hal can enumerate human holders directly, or can distinguish a valid
#   human principal from a nonexistent one.
#
# Usage:
#   ./TestC2a_holder_identity_disclosure.sh <active-envelope-id>

ENVELOPE_ID="${1:-}"
[[ -n "${ENVELOPE_ID}" ]] || {
    echo "Usage: $0 <active-envelope-id>" >&2
    exit 1
}

HAL_CONTAINER="${HAL_CONTAINER:-hal}"
HUB_URL="${HUB_URL:-http://fc-hub:8080}"

pass() {
    printf '\033[32m✓\033[0m %s\n' "$*"
}

fail() {
    printf '\033[31m✗\033[0m %s\n' "$*" >&2
}

section() {
    printf '\n============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

for cmd in docker jq; do
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo "Missing command: ${cmd}" >&2
        exit 1
    }
done

docker inspect "${HAL_CONTAINER}" >/dev/null 2>&1 || {
    echo "Hal container does not exist" >&2
    exit 1
}

FAILURES=0


hal_http() {
    local method="$1"
    local path="$2"
    local body="${3:-}"

    docker exec -i \
        -e HTTP_METHOD="${method}" \
        -e TARGET_URL="${HUB_URL}${path}" \
        -e REQUEST_BODY="${body}" \
        "${HAL_CONTAINER}" \
        python - <<'PY'
import json
import os
import urllib.error
import urllib.request

method = os.environ["HTTP_METHOD"]
url = os.environ["TARGET_URL"]
body = os.environ.get("REQUEST_BODY", "")

data = body.encode("utf-8") if body else None
headers = {}
if body:
    headers["Content-Type"] = "application/json"

request = urllib.request.Request(
    url,
    data=data,
    headers=headers,
    method=method,
)

try:
    with urllib.request.urlopen(request, timeout=5) as response:
        status = response.status
        raw = response.read().decode("utf-8", errors="replace")
except urllib.error.HTTPError as exc:
    status = exc.code
    raw = exc.read().decode("utf-8", errors="replace")
except Exception as exc:
    print(json.dumps({
        "transport_error": str(exc),
    }))
    raise SystemExit(0)

try:
    parsed = json.loads(raw)
except Exception:
    parsed = raw

print(json.dumps({
    "status": status,
    "body": parsed,
}))
PY
}


section "C2a.1 — direct identity disclosure"

BOUNDARY="$(
    hal_http GET "/administration/boundary"
)"

if printf '%s' "${BOUNDARY}" |
    jq -e '.transport_error' >/dev/null 2>&1
then
    printf '%s\n' "${BOUNDARY}" | jq .
    echo "Transport failure is not evidence of identity confidentiality." >&2
    exit 1
fi

STATUS="$(printf '%s' "${BOUNDARY}" | jq -r '.status')"

case "${STATUS}" in
    401|403|404)
        pass "Administration boundary is not readable from Hal (${STATUS})"
        ;;
    200)
        HUMAN_PRINCIPALS="$(
            printf '%s' "${BOUNDARY}" |
                jq -r '
                    [
                      (
                        .body.holders[]?
                        | select(.actor_type == "human")
                        | .principal
                      ),
                      (
                        .body.inference_actors[]?
                        | select(.actor_type == "human")
                        | .principal
                      )
                    ]
                    | unique
                    | .[]?
                '
        )"

        if [[ -n "${HUMAN_PRINCIPALS}" ]]; then
            printf 'Disclosed human principals:\n%s\n' \
                "${HUMAN_PRINCIPALS}" >&2
            fail "Hal can enumerate human holder identities through the Hub"
            FAILURES=$((FAILURES + 1))
        else
            pass "Hub response does not disclose human holder identities"
        fi
        ;;
    *)
        printf '%s\n' "${BOUNDARY}" | jq .
        echo "Unexpected boundary response; test precondition unresolved." >&2
        exit 1
        ;;
esac


section "C2a.2 — principal-existence oracle"

# Bob is used here only as a known positive control for the test harness.
# The property being tested is whether Hal can distinguish
# "valid principal" from "nonexistent principal" through the Hub.

UNKNOWN="c2a-no-such-principal-${RANDOM}-${RANDOM}"

BODY="$(
    jq -nc \
        --arg e "${ENVELOPE_ID}" \
        '{envelope_id:$e}'
)"

KNOWN_RESPONSE="$(
    hal_http POST \
        "/administration/holders/Bob/mint-ect" \
        "${BODY}"
)"

UNKNOWN_RESPONSE="$(
    hal_http POST \
        "/administration/holders/${UNKNOWN}/mint-ect" \
        "${BODY}"
)"

KNOWN_STATUS="$(printf '%s' "${KNOWN_RESPONSE}" | jq -r '.status // "transport"')"
UNKNOWN_STATUS="$(printf '%s' "${UNKNOWN_RESPONSE}" | jq -r '.status // "transport"')"

KNOWN_DETAIL="$(
    printf '%s' "${KNOWN_RESPONSE}" |
        jq -c '.body // .transport_error // null'
)"

UNKNOWN_DETAIL="$(
    printf '%s' "${UNKNOWN_RESPONSE}" |
        jq -c '.body // .transport_error // null'
)"

if [[ "${KNOWN_STATUS}" != "${UNKNOWN_STATUS}" ]] ||
   [[ "${KNOWN_DETAIL}" != "${UNKNOWN_DETAIL}" ]]
then
    printf 'Known-principal response   : HTTP %s %s\n' \
        "${KNOWN_STATUS}" "${KNOWN_DETAIL}" >&2
    printf 'Unknown-principal response : HTTP %s %s\n' \
        "${UNKNOWN_STATUS}" "${UNKNOWN_DETAIL}" >&2

    fail "Hub exposes a distinguishable principal-existence oracle to Hal"
    FAILURES=$((FAILURES + 1))
else
    pass "Known and nonexistent principal probes are indistinguishable"
fi


section "C2a invariant"

printf '%s\n' \
    "Hal must not learn human-holder identity from its permitted Hub aperture."

if (( FAILURES > 0 )); then
    printf '\n'
    printf 'C2a RED — %d identity-disclosure condition(s) observed\n' \
        "${FAILURES}" >&2
    exit 1
fi

printf '\n'
pass "C2a GREEN — human-holder identity is not disclosed to Hal"

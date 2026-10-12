#!/usr/bin/env bash
# TestA7_training_admission_bypass.sh
#
# Attack:
#   Prove whether Hospital C can cross the Flower execution boundary during
#   AB_BASE without Mode 1A guest admission.
#
# Method:
#   - keep a legitimate Hospital A Flower client
#   - stop normal B and C data-plane clients
#   - initialise a one-round AB_BASE lifecycle
#   - launch a controlled Hospital C client which deliberately does NOT:
#       * register with the Hub
#       * call wait_for_mode1a_training_admission()
#   - start the experiment
#   - CONFIRM A7 as soon as the unchanged Flower server invokes rogue C.fit()
#
# The rogue client raises immediately from fit(), so it does not submit an
# update. This tests admission at the execution boundary without intentionally
# poisoning the resulting model.
#
# Usage:
#   ./TestA7_training_admission_bypass.sh <active-envelope-id>
#
# Security verdict:
#   rc=0  A7 NOT CONFIRMED / rogue C was not selected
#   rc=1  A7 CONFIRMED / rogue C was selected for AB_BASE fit
#
# Harness/precondition failure:
#   rc=70

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENVELOPE_ID="${1:-}"
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
HUB_URL="${HUB_URL:-http://127.0.0.1:8080}"
TIMEOUT_S="${TIMEOUT_S:-120}"

ATTACK_CONTAINER="a7-rogue-c"
PROBE_PY="${SCRIPT_DIR}/a7_rogue_c_probe.py"

VAULT="${SRC_DIR}/vfp-governance/verifier/vault"
ENVELOPE_MANIFEST="${VAULT}/${ENVELOPE_ID}/run.json"

TMP="$(mktemp -d)"
MARKER="${TMP}/fit-called.json"

A_WAS_RUNNING=0
B_WAS_RUNNING=0
C_WAS_RUNNING=0
SERVER_WAS_RUNNING=0
ATTACK_STARTED=0
AUDIT_MODEL_RUN_ID=""

pass() {
    printf '\033[32m✓\033[0m %s\n' "$*"
}

note() {
    printf '\033[36m·\033[0m %s\n' "$*"
}

harness_fail() {
    printf '\033[31mHARNESS ERROR\033[0m %s\n' "$*" >&2
    exit 70
}

protected() {
    printf '\n\033[32mA7 NOT CONFIRMED\033[0m\n'
    printf '%s\n' "$*"
    exit 0
}

confirmed() {
    printf '\n\033[31mA7 CONFIRMED\033[0m\n'
    printf '%s\n' "$*"
    exit 1
}

section() {
    printf '\n============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

is_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

container_http() {
    local container="$1"
    local method="$2"
    local url="$3"
    local data="${4:-}"

    docker exec -i "${container}" python - \
        "${method}" "${url}" "${data}" <<'PY'
import sys
import urllib.error
import urllib.request

method = sys.argv[1]
url = sys.argv[2]
data = sys.argv[3].encode("utf-8") if sys.argv[3] else None
headers = {"Content-Type": "application/json"} if data is not None else {}

request = urllib.request.Request(
    url,
    data=data,
    headers=headers,
    method=method,
)
try:
    with urllib.request.urlopen(request, timeout=8) as response:
        print(response.read().decode("utf-8", errors="replace"))
except urllib.error.HTTPError as exc:
    print(exc.read().decode("utf-8", errors="replace"))
    sys.exit(22)
except Exception as exc:
    print(f"{type(exc).__name__}:{exc}", file=sys.stderr)
    sys.exit(23)
PY
}

hub_get() {
    container_http fc-hub GET "http://127.0.0.1:8080$1"
}

hub_post() {
    container_http fc-hub POST "http://127.0.0.1:8080$1" "${2:-}"
}

flower_status() {
    container_http flower-server GET "http://127.0.0.1:8081/status"
}

cleanup() {
    local rc=$?
    set +e

    if [[ "${ATTACK_STARTED}" == "1" ]]; then
        docker rm -f "${ATTACK_CONTAINER}" >/dev/null 2>&1 || true
    fi

    # Stop the audit lifecycle if the Hub still considers it running.
    hub_post "/experiments/${RUN_ID}/stop" '{}' >/dev/null 2>&1 || true

    # /vault is written by root inside flower-server. Restore/delete through
    # that container rather than mutating the host bind-mount directly.
    if docker inspect flower-server >/dev/null 2>&1 && is_running flower-server; then
        if [[ -f "${TMP}/run.json.before" ]]; then
            docker exec flower-server                 mkdir -p "/vault/${ENVELOPE_ID}"                 >/dev/null 2>&1 || true
            docker cp                 "${TMP}/run.json.before"                 "flower-server:/vault/${ENVELOPE_ID}/run.json"                 >/dev/null 2>&1 || true
        elif [[ -n "${ENVELOPE_ID}" ]]; then
            docker exec flower-server                 rm -f "/vault/${ENVELOPE_ID}/run.json"                 >/dev/null 2>&1 || true
        fi

        # Remove only the run allocated by this audit.
        if [[ -n "${AUDIT_MODEL_RUN_ID}"            && "${AUDIT_MODEL_RUN_ID}" != "${RUN_ID}" ]]; then
            docker exec flower-server                 rm -rf "/vault/runs/${AUDIT_MODEL_RUN_ID}"                 >/dev/null 2>&1 || true
        fi

        # Kill any half-open Flower lifecycle and return to the normal control
        # plane. The server re-registers/re-binds on restart.
        docker restart flower-server >/dev/null 2>&1 || true

        for _ in {1..30}; do
            BOUNDARY="$(hub_get /administration/boundary 2>/dev/null || true)"

            if [[ -n "${BOUNDARY}" ]] && \
            printf '%s' "${BOUNDARY}" | jq -e \
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
                ' >/dev/null 2>&1
            then
                break
            fi

            sleep 1
        done

        BOUNDARY="$(hub_get /administration/boundary 2>/dev/null || true)"

        printf '%s' "${BOUNDARY}" | jq -e \
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
            ' >/dev/null 2>&1 || {
                printf '%s\n' \
                    "A7 CLEANUP ERROR backend did not restore ${ENVELOPE_ID}" >&2
                rc=70
            }   
    fi

    # Restore client states exactly as found before A7.
    if [[ "${A_WAS_RUNNING}" == "1" ]]; then
        docker start flower-client-a >/dev/null 2>&1 || true
    else
        docker stop flower-client-a >/dev/null 2>&1 || true
    fi

    if [[ "${B_WAS_RUNNING}" == "1" ]]; then
        docker start flower-client-b >/dev/null 2>&1 || true
    else
        docker stop flower-client-b >/dev/null 2>&1 || true
    fi

    if [[ "${C_WAS_RUNNING}" == "1" ]]; then
        docker start flower-client-c >/dev/null 2>&1 || true
    else
        docker stop flower-client-c >/dev/null 2>&1 || true
    fi

    rm -rf "${TMP}"
    exit "${rc}"
}
trap cleanup EXIT

[[ -n "${ENVELOPE_ID}" ]] ||
    harness_fail "Usage: $0 <active-envelope-id>"

for cmd in docker jq grep sed date; do
    command -v "${cmd}" >/dev/null 2>&1 ||
        harness_fail "Missing command: ${cmd}"
done

[[ -s "${PROBE_PY}" ]] ||
    harness_fail "Missing helper: ${PROBE_PY}"

for container in fc-hub flower-server flower-client-a flower-client-b flower-client-c; do
    docker inspect "${container}" >/dev/null 2>&1 ||
        harness_fail "Missing container: ${container}"
done

is_running flower-client-a && A_WAS_RUNNING=1
is_running flower-client-b && B_WAS_RUNNING=1
is_running flower-client-c && C_WAS_RUNNING=1
is_running flower-server && SERVER_WAS_RUNNING=1

[[ "${SERVER_WAS_RUNNING}" == "1" ]] ||
    harness_fail "flower-server is not running"

if docker exec flower-server test -s "/vault/${ENVELOPE_ID}/run.json" 2>/dev/null; then
    docker cp         "flower-server:/vault/${ENVELOPE_ID}/run.json"         "${TMP}/run.json.before"         >/dev/null
fi

section "1. Verify active governed boundary"

BOUNDARY="$(hub_get /administration/boundary)" ||
    harness_fail "Cannot read Hub administration boundary"

printf '%s' "${BOUNDARY}" | jq -e \
    --arg e "${ENVELOPE_ID}" '
      .selected_envelope_id == $e
      and (
        [.envelopes[]
         | select(
             .envelope_id == $e
             and .bound == true
         )]
        | length == 1
      )
    ' >/dev/null ||
    harness_fail "Envelope ${ENVELOPE_ID} is not selected and bound"

pass "Envelope ${ENVELOPE_ID} is selected and bound"

section "2. Prepare AB_BASE with only legitimate A on the data plane"

# Reinitialise explicitly as AB_BASE. One round is enough because A7 stops at
# rogue fit selection, before a rogue update is returned.
INIT_BODY="$(
    jq -nc \
        --arg run "${RUN_ID}" '
        {
          run_id:$run,
          phase:"AB_BASE",
          rounds:1,
          min_clients:2,
          local_epochs:1
        }'
)"

INIT="$(hub_post /experiments/initialise "${INIT_BODY}")" ||
    harness_fail "Hub experiment initialise failed"

printf '%s' "${INIT}" | jq -e \
    --arg e "${ENVELOPE_ID}" '
      .status == "initialised"
      and .active_envelope_id == $e
      and .backend_bound == true
    ' >/dev/null ||
    harness_fail "AB_BASE initialise did not preserve the active boundary"

# Client registrations are Hub in-memory state. A Hub restart can forget A/B
# while their containers remain alive. Restart them after initialise so each
# client performs its normal startup registration against current Hub state.
docker restart flower-client-a flower-client-b >/dev/null
sleep 3

# Wait until Hub has at least the normal A/B control-plane registrations.
ready=0
STATUS=""
for _ in $(seq 1 30); do
    STATUS="$(hub_get "/experiments/${RUN_ID}/status" 2>/dev/null || true)"
    if jq -e '
        .registered_client_count >= 2
        and .can_start == true
    ' >/dev/null 2>&1 <<<"${STATUS}"; then
        ready=1
        break
    fi
    sleep 1
done

if [[ "${ready}" != "1" ]]; then
    printf '\nHub experiment status at readiness failure:\n' >&2
    printf '%s\n' "${STATUS}" | jq . >&2 2>/dev/null || \
        printf '%s\n' "${STATUS}" >&2
    harness_fail "Hub did not reach normal A/B START readiness"
fi

# Now remove B and normal C from the Flower data plane. A remains legitimate.
docker stop flower-client-b flower-client-c >/dev/null 2>&1 || true
docker restart flower-client-a >/dev/null

pass "Hub control plane is A/B-ready; data plane now contains legitimate A only"

section "3. Launch rogue C without Hub registration or guest admission"

CLIENT_IMAGE="$(docker inspect -f '{{.Config.Image}}' flower-client-c)"
NETWORK="$(
    docker inspect -f \
      '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}' \
      flower-client-c | head -n1
)"
[[ -n "${CLIENT_IMAGE}" && -n "${NETWORK}" ]] ||
    harness_fail "Cannot determine Flower client image/network"

docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' flower-client-c \
    | grep -v '^DEVICE=' \
    >"${TMP}/rogue.env"
printf 'DEVICE=cpu\n' >>"${TMP}/rogue.env"

docker rm -f "${ATTACK_CONTAINER}" >/dev/null 2>&1 || true

docker run -d \
    --name "${ATTACK_CONTAINER}" \
    --network "${NETWORK}" \
    --env-file "${TMP}/rogue.env" \
    -v "${PROBE_PY}:/audit/a7_rogue_c_probe.py:ro" \
    -v "${TMP}:/audit/out" \
    --entrypoint python \
    "${CLIENT_IMAGE}" \
    -u /audit/a7_rogue_c_probe.py \
    >/dev/null

ATTACK_STARTED=1

pass "Rogue C is retrying the Flower endpoint with no Hub/admission call"

section "4. Start unchanged AB_BASE and watch the execution boundary"

START="$(hub_post "/experiments/${RUN_ID}/start" '{}')" ||
    harness_fail "Hub START failed"

printf '%s' "${START}" | jq -e '.status == "running"' >/dev/null ||
    harness_fail "Hub did not start AB_BASE"

start_time="$(date +%s)"
while true; do
    if [[ -s "${MARKER}" ]]; then
        break
    fi

    # A crashed probe is a harness failure, not a security protection result.
    if ! is_running "${ATTACK_CONTAINER}"; then
        printf '\nRogue probe logs:\n' >&2
        docker logs "${ATTACK_CONTAINER}" 2>&1 | tail -n 50 >&2 || true
        probe_rc="$(
            docker inspect -f '{{.State.ExitCode}}'                 "${ATTACK_CONTAINER}" 2>/dev/null || echo unknown
        )"
        harness_fail             "Rogue C probe exited before fit evidence was produced (rc=${probe_rc})"
    fi

    FSTATUS="$(flower_status 2>/dev/null || true)"
    if jq . >/dev/null 2>&1 <<<"${FSTATUS}"; then
        candidate="$(jq -r '.model_run_id // empty' <<<"${FSTATUS}")"
        if [[ -n "${candidate}" ]]; then
            AUDIT_MODEL_RUN_ID="${candidate}"
        fi
    fi

    now="$(date +%s)"
    if (( now - start_time >= TIMEOUT_S )); then
        note "Rogue C remained live but was not selected within ${TIMEOUT_S}s"
        docker logs "${ATTACK_CONTAINER}" 2>&1 | tail -n 30 >&2 || true
        protected "The live rogue Hospital C client was not selected by the AB_BASE Flower execution boundary."
    fi

    sleep 1
done

pass "Unadmitted rogue C received a Flower fit instruction"

section "5. Verify that selection occurred under AB_BASE with no guest admission"

cat "${MARKER}" | jq .

FSTATUS="$(flower_status)" ||
    harness_fail "Cannot read Flower status after rogue selection"

AUDIT_MODEL_RUN_ID="$(jq -r '.model_run_id // empty' <<<"${FSTATUS}")"

printf '%s' "${FSTATUS}" | jq -e '
    .training.phase == "AB_BASE"
    and (.training.guest_admission_decision_id == null)
    and (.training.guest_admission_run_id == null)
' >/dev/null || {
    printf '%s\n' "${FSTATUS}" | jq . >&2
    harness_fail "Rogue selection did not occur under clean AB_BASE/no-guest-admission state"
}

jq -e '
    .hospital == "C"
    and .org_id == "org://HospitalC"
    and .event == "fit_called"
' "${MARKER}" >/dev/null ||
    harness_fail "Rogue fit marker does not identify Hospital C"

printf '\nEvidence:\n'
printf '%s\n' "${FSTATUS}" | jq '{
    model_run_id,
    phase: .training.phase,
    round: .training.round,
    guest_admission_decision_id: .training.guest_admission_decision_id,
    guest_admission_run_id: .training.guest_admission_run_id
}'
cat "${MARKER}" | jq .

confirmed \
"Unregistered/unadmitted Hospital C crossed the AB_BASE Flower execution boundary and was selected for fit without a Mode 1A guest-admission decision."

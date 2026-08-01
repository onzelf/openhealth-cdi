#!/usr/bin/env bash
# Post-envelope smoke test for the current OpenHealth lifecycle.
#
# Usage:
#   ./Test1B_postEnvelope.sh <envelope_id> [run_id] [timeout_seconds]
#
# Defaults:
#   run_id          = local-pathmnist-ab-001
#   timeout_seconds = 1800
#
# Note:
#   This script deliberately does not require curl inside the containers.
#   Hub/Flower HTTP calls are made with Python stdlib urllib from inside
#   the relevant Python containers.

set -euo pipefail

ENVELOPE_ID="${1:-}"
RUN_ID="${2:-local-pathmnist-ab-001}"
TIMEOUT_S="${3:-1800}"

if [[ -z "${ENVELOPE_ID}" ]]; then
  echo "Usage: $0 <envelope_id> [run_id] [timeout_seconds]"
  exit 1
fi

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
pass() { printf "\033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[33m!\033[0m %s\n" "$*"; }
fail() { printf "\033[31m✗\033[0m %s\n" "$*"; exit 1; }
hr()   { printf "\n%s\n\n" "────────────────────────────────────────"; }

command -v docker >/dev/null || fail "docker is not installed"
command -v jq >/dev/null || fail "jq is not installed on host"

need_running_container() {
  local name="$1"
  docker ps --format '{{.Names}}' | grep -qx "${name}" \
    || fail "Container is not running: ${name}"
}

container_http() {
  local container="$1"
  local method="$2"
  local url="$3"
  local data="${4:-}"

  docker exec -i "${container}" python - \
    "${method}" "${url}" "${data}" <<'PYCODE'
import sys
import urllib.error
import urllib.request

method = sys.argv[1]
url = sys.argv[2]
data = sys.argv[3].encode("utf-8") if sys.argv[3] else None
headers = {"Content-Type": "application/json"} if data is not None else {}

req = urllib.request.Request(
    url,
    data=data,
    headers=headers,
    method=method,
)
try:
    with urllib.request.urlopen(req, timeout=5) as response:
        body = response.read().decode("utf-8", errors="replace")
        print(body)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    print(f"HTTP_ERROR {exc.code} {exc.reason}")
    print(body)
    sys.exit(22)
except Exception as exc:
    print(f"REQUEST_ERROR {type(exc).__name__}: {exc}")
    sys.exit(23)
PYCODE
}

require_json() {
  local label="$1"
  local payload="$2"

  if ! jq . >/dev/null 2>&1 <<<"${payload}"; then
    echo "${label} did not return JSON:" >&2
    echo "${payload}" >&2
    return 1
  fi
}

hub_status() {
  container_http fc-hub GET \
    "http://127.0.0.1:8080/experiments/${RUN_ID}/status"
}

hub_initialise() {
  local payload
  payload="$(jq -nc --arg run "${RUN_ID}" '{run_id: $run}')"
  container_http fc-hub POST \
    "http://127.0.0.1:8080/experiments/initialise" \
    "${payload}"
}

hub_start() {
  container_http fc-hub POST \
    "http://127.0.0.1:8080/experiments/${RUN_ID}/start"
}

flower_status() {
  container_http flower-server GET \
    "http://127.0.0.1:8081/status"
}

wait_until_ready() {
  local start now payload active bound count minimum can_start
  start="$(date +%s)"

  while true; do
    payload="$(hub_status 2>/dev/null || true)"

    if [[ -n "${payload}" ]] && jq . >/dev/null 2>&1 <<<"${payload}"; then
      active="$(jq -r '.active_envelope_id // empty' <<<"${payload}")"
      bound="$(jq -r '.backend_bound // false' <<<"${payload}")"
      count="$(jq -r '.registered_client_count // 0' <<<"${payload}")"
      minimum="$(jq -r '.min_clients // 0' <<<"${payload}")"
      can_start="$(jq -r '.can_start // false' <<<"${payload}")"

      printf 'Hub: envelope=%s bound=%s clients=%s/%s can_start=%s\n' \
        "${active:-none}" "${bound}" "${count}" "${minimum}" "${can_start}"

      if [[ -n "${active}" && "${active}" != "${ENVELOPE_ID}" ]]; then
        fail "Hub is bound to envelope ${active}, not ${ENVELOPE_ID}"
      fi

      if [[ "${active}" == "${ENVELOPE_ID}" \
         && "${bound}" == "true" \
         && "${can_start}" == "true" ]]; then
        return 0
      fi
    elif [[ -n "${payload}" ]]; then
      warn "Hub status is not JSON yet: ${payload}"
    fi

    now="$(date +%s)"
    (( now - start < 120 )) || return 1
    sleep 2
  done
}

wait_training_done() {
  local previous_model_run_id="$1"
  local start now payload state round rounds error model_run_id bound_envelope
  local manifest manifest_run_id manifest_session_id
  start="$(date +%s)"

  while true; do
    payload="$(flower_status 2>/dev/null || true)"

    if [[ -n "${payload}" ]] && jq . >/dev/null 2>&1 <<<"${payload}"; then
      state="$(jq -r '.training.status // empty' <<<"${payload}")"
      round="$(jq -r '.training.round // 0' <<<"${payload}")"
      rounds="$(jq -r '.training.rounds // 0' <<<"${payload}")"
      error="$(jq -r '.training.error // empty' <<<"${payload}")"
      model_run_id="$(jq -r '.model_run_id // empty' <<<"${payload}")"
      bound_envelope="$(
        jq -r '.bound_envelope.envelope_id // empty' <<<"${payload}"
      )"

      printf 'Training: status=%s round=%s/%s model_run=%s\n' \
        "${state:-unknown}" \
        "${round}" \
        "${rounds}" \
        "${model_run_id:-none}"

      if [[ -n "${bound_envelope}" && "${bound_envelope}" != "${ENVELOPE_ID}" ]]; then
        echo "Flower is bound to ${bound_envelope}, not ${ENVELOPE_ID}" >&2
        return 1
      fi

      case "${state}" in
        done)
          if [[ -z "${model_run_id}" ]]; then
            warn "Ignoring done state without an allocated model run"
          elif [[ "${model_run_id}" == "${previous_model_run_id}" ]]; then
            warn "Ignoring stale done state for ${model_run_id}"
          else
            manifest="$(
              docker exec flower-server \
                cat "/vault/${ENVELOPE_ID}/run.json" 2>/dev/null || true
            )"
            if jq . >/dev/null 2>&1 <<<"${manifest}"; then
              manifest_run_id="$(jq -r '.run_id // empty' <<<"${manifest}")"
              manifest_session_id="$(
                jq -r '.session_id // empty' <<<"${manifest}"
              )"
              if [[ "${manifest_run_id}" == "${model_run_id}" \
                 && "${manifest_session_id}" == "${ENVELOPE_ID}" ]]; then
                COMPLETED_MODEL_RUN_ID="${model_run_id}"
                return 0
              fi
            fi
            warn "Waiting for envelope manifest for ${model_run_id}"
          fi
          ;;
        error)
          [[ -n "${error}" ]] && echo "Server error: ${error}" >&2
          return 1
          ;;
      esac
    elif [[ -n "${payload}" ]]; then
      warn "Flower status is not JSON yet: ${payload}"
    fi

    now="$(date +%s)"
    (( now - start < TIMEOUT_S )) || return 1
    sleep 5
  done
}

bold "=== OpenHealth post-envelope smoke test ==="
echo "Envelope ID: ${ENVELOPE_ID}"
echo "Run ID:      ${RUN_ID}"

hr
bold "Step 1: Container preflight"
need_running_container fc-hub
need_running_container flower-server
need_running_container flower-client-a
need_running_container flower-client-b
pass "Hub, server, and A/B clients are running"

hr
bold "Step 2: Reinitialise the existing run lifecycle"
INITIALISE_RESPONSE="$(hub_initialise)"
require_json "Hub initialise endpoint" "${INITIALISE_RESPONSE}" ||
  fail "Initialise returned non-JSON"
echo "${INITIALISE_RESPONSE}" | jq .

INITIALISE_STATUS="$(jq -r '.status // empty' <<<"${INITIALISE_RESPONSE}")"
INITIALISE_ENVELOPE="$(
  jq -r '.active_envelope_id // empty' <<<"${INITIALISE_RESPONSE}"
)"
[[ "${INITIALISE_STATUS}" == "initialised" ]] ||
  fail "Initialise failed: status=${INITIALISE_STATUS:-missing}"
[[ "${INITIALISE_ENVELOPE}" == "${ENVELOPE_ID}" ]] ||
  fail "Initialise did not preserve envelope ${ENVELOPE_ID}"
pass "Run returned to waiting while preserving the selected envelope"

hr
bold "Step 3: Wait for bound envelope and START readiness"
if wait_until_ready; then
  pass "Envelope is bound and experiment can start"
else
  payload="$(hub_status 2>/dev/null || true)"
  [[ -n "${payload}" ]] && echo "${payload}" | jq . 2>/dev/null || echo "${payload}"
  fail "Experiment did not become start-ready within 120 seconds"
fi

# Capture the previous artefact pointer so a stale Flower "done" state cannot
# satisfy this invocation.
FLOWER_BEFORE_START="$(flower_status)"
require_json "Flower status endpoint" "${FLOWER_BEFORE_START}" ||
  fail "Flower status returned non-JSON before START"
PREVIOUS_MODEL_RUN_ID="$(
  jq -r '.model_run_id // empty' <<<"${FLOWER_BEFORE_START}"
)"
PREVIOUS_TRAINING_STATUS="$(
  jq -r '.training.status // empty' <<<"${FLOWER_BEFORE_START}"
)"
PREVIOUS_BOUND_ENVELOPE="$(
  jq -r '.bound_envelope.envelope_id // empty' <<<"${FLOWER_BEFORE_START}"
)"
[[ "${PREVIOUS_BOUND_ENVELOPE}" == "${ENVELOPE_ID}" ]] ||
  fail "Flower is not bound to envelope ${ENVELOPE_ID} before START"
[[ "${PREVIOUS_TRAINING_STATUS}" != "running" ]] ||
  fail "Flower already reports a running training job before START"

hr
bold "Step 4: Simulate the START button"
START_RESPONSE="$(hub_start)"
require_json "Hub START endpoint" "${START_RESPONSE}" || fail "START returned non-JSON"
echo "${START_RESPONSE}" | jq .

START_STATUS="$(jq -r '.status // empty' <<<"${START_RESPONSE}")"
[[ "${START_STATUS}" == "running" ]] ||
  fail "START did not create a new running lifecycle: status=${START_STATUS:-missing}"
pass "Experiment START accepted as a new running lifecycle"

hr
bold "Step 5: Wait for correlated Flower training completion"
COMPLETED_MODEL_RUN_ID=""
if wait_training_done "${PREVIOUS_MODEL_RUN_ID}"; then
  pass "Training completed as new model run ${COMPLETED_MODEL_RUN_ID}"
else
  payload="$(flower_status 2>/dev/null || true)"
  [[ -n "${payload}" ]] && echo "${payload}" | jq . 2>/dev/null || echo "${payload}"
  fail "Training failed or timed out after ${TIMEOUT_S} seconds"
fi

hr
bold "Step 6: Verify envelope-bound run evidence"
EVIDENCE_PATH="/vault/${ENVELOPE_ID}/run.json"
EVIDENCE_JSON="$(
  docker exec flower-server cat "${EVIDENCE_PATH}" 2>/dev/null || true
)"
require_json "Envelope run manifest" "${EVIDENCE_JSON}" ||
  fail "Missing or invalid ${EVIDENCE_PATH}"

EVIDENCE_RUN_ID="$(jq -r '.run_id // empty' <<<"${EVIDENCE_JSON}")"
EVIDENCE_SESSION_ID="$(jq -r '.session_id // empty' <<<"${EVIDENCE_JSON}")"
[[ "${EVIDENCE_RUN_ID}" == "${COMPLETED_MODEL_RUN_ID}" ]] ||
  fail "Manifest run_id does not match the completed model run"
[[ "${EVIDENCE_SESSION_ID}" == "${ENVELOPE_ID}" ]] ||
  fail "Manifest session_id does not match the envelope"

echo "${EVIDENCE_JSON}" | jq .
pass "Envelope manifest binds ${COMPLETED_MODEL_RUN_ID} to ${ENVELOPE_ID}"

hr
bold "=== PASS ==="
echo "Envelope ${ENVELOPE_ID} was bound, explicitly started, trained, and evidenced."
echo "Run artefact checks remain in Test1C_verifyABRounds.sh."

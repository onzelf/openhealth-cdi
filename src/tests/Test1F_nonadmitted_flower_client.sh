#!/usr/bin/env bash
# Test1F: a Flower client that can reach the server but is not admitted must not train.
# Issue #7 acceptance test, L0 (Flower server and clients as containers on this host).
#
# Usage:
#   ./Test1F_nonadmitted_flower_client.sh <envelope_id> [run_id] [--fail-closed]
#
# What it does, with the real A and B clients running and holding their execution keys:
#   1. Starts three rogue clients on the same Docker network as the real ones:
#        no-key     claims Hospital A, no execution key
#        wrong-key  claims Hospital A, signs with a key nobody registered
#        stolen-a   holds Hospital A's real key (a second connection for one hospital)
#   2. Runs one round through the hub (initialise with rounds=1, START), like Test1B.
#   3. Checks the Flower server's evidence:
#        - the round admitted exactly Hospital A and Hospital B;
#        - no-key and wrong-key were refused as invalid_proof, stolen-a as duplicate_org
#          (whichever of the two Hospital A connections answered first is admitted);
#        - participants.json lists only Hospital A and Hospital B;
#        - the run completed with rounds_completed = 1.
#   With --fail-closed it then stops the real Hospital B client, starts a rogue that claims
#   Hospital B, and checks the round fails closed (round_admission_failed, no aggregation).
#   Then, with B still stopped and no rogue, a run fails within the server's
#   CLIENT_WAIT_TIMEOUT_SECONDS (default 300) although Flower's sampling threshold is never
#   met; after each failure the hub says 'failed', not 'completed'. Finally B is started again
#   and an A+B run completes. Nothing is restarted between runs.
#
# Needs: docker, jq, openssl; the dataset at ../data/pathmnist.npz (as demo_start.sh).
set -euo pipefail

ENVELOPE_ID="${1:-}"
RUN_ID="${2:-local-pathmnist-ab-001}"
case "${RUN_ID}" in --*) RUN_ID="local-pathmnist-ab-001" ;; esac  # "<envelope_id> --fail-closed"
FAIL_CLOSED="no"
for arg in "$@"; do [[ "${arg}" == "--fail-closed" ]] && FAIL_CLOSED="yes"; done
[[ -n "${ENVELOPE_ID}" && "${ENVELOPE_ID}" != --* ]] || { echo "Usage: $0 <envelope_id> [run_id] [--fail-closed]"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SRC_DIR}/.." && pwd)"
EXECUTION_KEYS_DIR="${SRC_DIR}/vfp-governance/verifier/execution_keys"
PATHMNIST_HOST="${PATHMNIST_HOST:-${REPO_ROOT}/../data/pathmnist.npz}"
CLIENT_IMAGE="${CLIENT_IMAGE:-$(docker inspect --format '{{.Config.Image}}' flower-client-a 2>/dev/null || echo fcac/flower-client:local)}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
CLIENT_WAIT_S="${CLIENT_WAIT_S:-300}"  # must match the server's CLIENT_WAIT_TIMEOUT_SECONDS
ROGUES=()

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
pass() { printf "\033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[33m!\033[0m %s\n" "$*"; }
fail() { printf "\033[31m✗\033[0m %s\n" "$*"; exit 1; }
hr()   { printf "\n%s\n\n" "────────────────────────────────────────"; }

cleanup() {
  for name in "${ROGUES[@]:-}"; do
    [[ -n "${name}" ]] && docker rm -f "${name}" >/dev/null 2>&1 || true
  done
  if [[ "${FAIL_CLOSED}" == "yes" ]]; then
    docker start flower-client-b >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

command -v docker >/dev/null || fail "docker is not installed"
command -v jq >/dev/null || fail "jq is not installed"
command -v openssl >/dev/null || fail "openssl is not installed"
for name in fc-hub flower-server flower-client-a flower-client-b; do
  docker ps --format '{{.Names}}' | grep -qx "${name}" || fail "Container is not running: ${name}"
done
[[ -s "${EXECUTION_KEYS_DIR}/flower-execution-HospitalA.privhex" ]] \
  || fail "Missing ${EXECUTION_KEYS_DIR}/flower-execution-HospitalA.privhex (run preflight_bootstrap.sh and bootstrap_members.sh)"
[[ -s "${PATHMNIST_HOST}" ]] || fail "Missing dataset ${PATHMNIST_HOST}"

container_http() {
  local container="$1" method="$2" url="$3" data="${4:-}"
  docker exec -i "${container}" python - "${method}" "${url}" "${data}" <<'PYCODE'
import sys, urllib.error, urllib.request
method, url = sys.argv[1], sys.argv[2]
data = sys.argv[3].encode("utf-8") if sys.argv[3] else None
headers = {"Content-Type": "application/json"} if data is not None else {}
req = urllib.request.Request(url, data=data, headers=headers, method=method)
try:
    with urllib.request.urlopen(req, timeout=5) as response:
        print(response.read().decode("utf-8", errors="replace"))
except urllib.error.HTTPError as exc:
    print(exc.read().decode("utf-8", errors="replace")); sys.exit(22)
except Exception as exc:
    print(f"REQUEST_ERROR {type(exc).__name__}: {exc}"); sys.exit(23)
PYCODE
}
hub_status()    { container_http fc-hub GET "http://127.0.0.1:8080/experiments/${RUN_ID}/status"; }
flower_status() { container_http flower-server GET "http://127.0.0.1:8081/status"; }
# The server restarts itself in place on START (os.execv), so its control API can be down for a
# moment: retry until it answers with JSON.
flower_json() {
  local out _
  for _ in $(seq 30); do
    if out="$(flower_status 2>/dev/null)" && jq -e . >/dev/null 2>&1 <<<"${out}"; then
      printf '%s\n' "${out}"; return 0
    fi
    sleep 1
  done
  return 1
}
hub_initialise() {
  container_http fc-hub POST "http://127.0.0.1:8080/experiments/initialise" \
    "$(jq -nc --arg run "${RUN_ID}" '{run_id: $run, rounds: 1}')"
}
hub_start() { container_http fc-hub POST "http://127.0.0.1:8080/experiments/${RUN_ID}/start"; }

# A rogue client: the real client image and settings, with a different identity or key.
start_rogue() {
  local name="$1" hospital="$2" key_mode="$3"
  local env_args=()
  while IFS= read -r line; do
    case "${line}" in
      HOSPITAL=*|ORG_ID=*|EXECUTION_KEY_FILE=*|EXECUTION_KEY_HEX=*|RETRY_INTERVAL=*|"") ;;
      *) env_args+=(-e "${line}") ;;
    esac
  done < <(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' flower-client-a)
  # Rogues retry every second (the real clients every 10 s), so they are connected when the round
  # samples and every one of them is challenged.
  env_args+=(-e "HOSPITAL=${hospital}" -e "ORG_ID=org://Hospital${hospital}" -e "RETRY_INTERVAL=1")
  local mounts=(-v "${PATHMNIST_HOST}:/tmp/medmnist/pathmnist.npz:ro")
  case "${key_mode}" in
    none) ;;
    wrong) env_args+=(-e "EXECUTION_KEY_HEX=$(openssl rand -hex 32)") ;;
    stolen-a)
      mounts+=(-v "${EXECUTION_KEYS_DIR}/flower-execution-HospitalA.privhex:/run/secrets/execution.key:ro")
      env_args+=(-e "EXECUTION_KEY_FILE=/run/secrets/execution.key") ;;
  esac
  local gpu_args=()
  if docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' flower-client-a | grep -qx 'DEVICE=cuda'; then
    gpu_args=(--gpus all)
  fi
  docker rm -f "${name}" >/dev/null 2>&1 || true
  docker run -d --name "${name}" --network fc ${gpu_args[@]+"${gpu_args[@]}"} "${mounts[@]}" "${env_args[@]}" "${CLIENT_IMAGE}" >/dev/null
  ROGUES+=("${name}")
  pass "Started rogue ${name} (claims Hospital ${hospital}, key: ${key_mode})"
}

run_one_round() {
  local expect="$1"   # done | error
  local response status start payload state model_run_id previous
  response="$(hub_initialise)" || fail "Initialise failed: ${response}"; echo "${response}" | jq -c '{status, active_envelope_id}' || true
  status="$(jq -r '.status // empty' <<<"${response}")"
  [[ "${status}" == "initialised" ]] || fail "Initialise failed: ${response}"
  start="$(date +%s)"
  while true; do
    payload="$(hub_status 2>/dev/null || true)"
    if [[ "$(jq -r '.active_envelope_id // empty' <<<"${payload}" 2>/dev/null)" == "${ENVELOPE_ID}" \
       && "$(jq -r '.can_start // false' <<<"${payload}" 2>/dev/null)" == "true" ]]; then break; fi
    (( $(date +%s) - start < 180 )) || fail "Experiment not start-ready: ${payload}"
    sleep 3
  done
  previous="$(flower_json | jq -r '.model_run_id // empty')" || fail "The Flower control API is not answering"
  # Give the rogue containers time to start (loading torch takes about 20 s), so they are
  # already retrying, once a second, when the server opens its port after START.
  sleep "${ROGUE_CONNECT_WAIT_S:-60}"
  response="$(hub_start)" || fail "START failed: ${response}"; status="$(jq -r '.status // empty' <<<"${response}")"
  [[ "${status}" == "running" ]] || fail "START failed: ${response}"
  start="$(date +%s)"
  while true; do
    payload="$(flower_json || true)"  # empty while the server restarts itself
    state="$(jq -r '.training.status // empty' <<<"${payload}" 2>/dev/null || true)"
    model_run_id="$(jq -r '.model_run_id // empty' <<<"${payload}" 2>/dev/null || true)"
    if [[ -n "${model_run_id}" && "${model_run_id}" != "${previous}" && "${state}" == "${expect}" ]]; then
      MODEL_RUN_ID="${model_run_id}"; return 0
    fi
    # Only the new run's outcome counts: just after START the server still reports the
    # previous run. A new run that ends the other way fails the test at once.
    if [[ -n "${model_run_id}" && "${model_run_id}" != "${previous}" && "${state}" =~ ^(done|error)$ ]]; then
      fail "Run ${model_run_id} ended '${state}', expected '${expect}': $(jq -c '.training' <<<"${payload}")"
    fi
    (( $(date +%s) - start < TIMEOUT_S )) || fail "Timed out waiting for state ${expect}: $(jq -c '.training' <<<"${payload}" 2>/dev/null)"
    sleep 5
  done
}

events_for() { docker exec flower-server cat "/vault/runs/$1/events.jsonl"; }
# The server tells the hub just after its own status changes, so allow a few seconds.
hub_reports() {
  local reported="" _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    reported="$(hub_status 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)"
    if [[ "${reported}" == "$1" ]]; then pass "The hub reports the run as '$1'"; return 0; fi
    sleep 3
  done
  fail "The hub reports '${reported}' for run ${MODEL_RUN_ID}, expected '$1'"
}
SERVER_STARTED_AT="$(docker inspect --format '{{.State.StartedAt}}' flower-server)"
HUB_STARTED_AT="$(docker inspect --format '{{.State.StartedAt}}' fc-hub)"

bold "=== Test1F: non-admitted Flower clients ==="
echo "Envelope: ${ENVELOPE_ID}  Run: ${RUN_ID}  Image: ${CLIENT_IMAGE}"
hr

bold "Step 1: Rogue clients on the Flower network"
start_rogue rogue-no-key   A none
start_rogue rogue-wrong-key A wrong
start_rogue rogue-stolen-a A stolen-a
hr

bold "Step 2: One round with the real A and B clients plus the rogues"
MODEL_RUN_ID=""
run_one_round "done"
pass "Run ${MODEL_RUN_ID} completed"
hub_reports completed  # the hub hears only after the evidence files are written
EVENTS="$(events_for "${MODEL_RUN_ID}")"
hr

bold "Step 3: Evidence"
ADMITTED="$(jq -sc '[.[] | select(.event_type == "round_clients_admitted")] | map(.participants)' <<<"${EVENTS}")"
echo "Admitted per round: ${ADMITTED}"
[[ "${ADMITTED}" == '[["org://HospitalA","org://HospitalB"]]' ]] || fail "Round did not admit exactly Hospital A and Hospital B"
pass "The round admitted exactly Hospital A and Hospital B"

REJECTED="$(jq -sc '[.[] | select(.event_type == "flower_client_rejected") | .reason]' <<<"${EVENTS}")"
echo "Refused: ${REJECTED}"
# Count connections, not events: each admission retry challenges every client again.
REFUSED_A="$(jq -s '[.[] | select(.event_type == "flower_client_rejected" and .reason == "invalid_proof:org://HospitalA") | .client] | unique | length' <<<"${EVENTS}")"
[[ "${REFUSED_A}" -ge 2 ]] || fail "Expected no-key and wrong-key to be refused as invalid_proof (${REFUSED_A} connection(s))"
[[ "$(jq '[.[] | select(. == "duplicate_org:org://HospitalA")] | length' <<<"${REJECTED}")" -ge 1 ]] \
  || fail "Expected the second Hospital A connection to be refused as duplicate_org"
pass "no-key and wrong-key refused (invalid_proof); second Hospital A connection refused (duplicate_org)"

PARTICIPANTS="$(docker exec flower-server cat "/vault/runs/${MODEL_RUN_ID}/participants.json" | jq -c '[.participants[].participant_id] | sort')"
[[ "${PARTICIPANTS}" == '["org://HospitalA","org://HospitalB"]' ]] || fail "participants.json lists ${PARTICIPANTS}"
pass "participants.json lists only Hospital A and Hospital B"

ROUNDS_DONE="$(docker exec flower-server cat "/vault/runs/${MODEL_RUN_ID}/final_model_metadata.json" | jq -r '.rounds_completed')"
[[ "${ROUNDS_DONE}" == "1" ]] || fail "final_model_metadata rounds_completed=${ROUNDS_DONE}"
pass "rounds_completed = 1"

if [[ "${FAIL_CLOSED}" == "yes" ]]; then
  hr
  bold "Step 4: Hospital B absent, a rogue claims Hospital B: the round must fail closed"
  docker stop flower-client-b >/dev/null
  start_rogue rogue-claims-b B wrong
  run_one_round "error"
  EVENTS="$(events_for "${MODEL_RUN_ID}")"
  jq -se 'any(.[]; .event_type == "round_admission_failed")' <<<"${EVENTS}" >/dev/null \
    || fail "No round_admission_failed event"
  if jq -se 'any(.[]; .event_type == "round_fit_aggregated")' <<<"${EVENTS}" >/dev/null; then
    fail "A round was aggregated although admission failed"
  fi
  pass "Round failed closed; nothing aggregated (a reachable rogue cannot stand in for Hospital B)"
  hub_reports failed

  hr
  bold "Step 5: Hospital B absent, no rogue: the run must fail in bounded time"
  for name in "${ROGUES[@]}"; do docker rm -f "${name}" >/dev/null 2>&1 || true; done  # no rogue at all
  run_one_round "error"
  EVENTS="$(events_for "${MODEL_RUN_ID}")"
  jq -se 'any(.[]; .event_type == "round_clients_missing")' <<<"${EVENTS}" >/dev/null \
    || fail "No round_clients_missing event: $(jq -sc '[.[] | .event_type]' <<<"${EVENTS}")"
  if jq -se 'any(.[]; .event_type == "round_fit_aggregated")' <<<"${EVENTS}" >/dev/null; then
    fail "A round was aggregated although Hospital B never connected"
  fi
  WAITED="$(jq -s '[.[] | select(.event_type == "round_fit_configured" or .event_type == "round_clients_missing")
    | .timestamp | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601] | .[1] - .[0]' <<<"${EVENTS}")"
  (( WAITED >= CLIENT_WAIT_S - 5 && WAITED <= CLIENT_WAIT_S + 30 )) \
    || fail "The round waited ${WAITED} s, expected about ${CLIENT_WAIT_S} s"
  pass "Round failed after waiting ${WAITED} s for clients (round_clients_missing); nothing aggregated"
  hub_reports failed

  hr
  bold "Step 6: Hospital B back: an A+B run completes without restarting anything"
  docker start flower-client-b >/dev/null
  run_one_round "done"
  ADMITTED="$(events_for "${MODEL_RUN_ID}" | jq -sc '[.[] | select(.event_type == "round_clients_admitted")] | map(.participants)')"
  [[ "${ADMITTED}" == '[["org://HospitalA","org://HospitalB"]]' ]] || fail "Round admitted ${ADMITTED}"
  pass "Run ${MODEL_RUN_ID} admitted exactly Hospital A and Hospital B"
  hub_reports completed
fi

[[ "$(docker inspect --format '{{.State.StartedAt}}' flower-server)" == "${SERVER_STARTED_AT}" ]] \
  || fail "The flower-server container was restarted during the test"
[[ "$(docker inspect --format '{{.State.StartedAt}}' fc-hub)" == "${HUB_STARTED_AT}" ]] \
  || fail "The fc-hub container was restarted during the test"
pass "The flower-server and fc-hub containers were not restarted"

hr
bold "=== Test1F: PASS ==="

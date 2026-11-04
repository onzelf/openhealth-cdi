#!/usr/bin/env bash
# Test1F on L1-B1, the five accounts, from a workstation: issue #7 end to end. Uses the AWS CLI
# profiles for the hospital and Flower accounts and ssh to the governance host for the hub, the
# Flower control API and the vault. Nothing is restarted between the three runs.
#
#   HOST=ubuntu@<host> PROFILE_A=<profile> PROFILE_B=<profile> PROFILE_F=<profile> bash test1f-b1.sh <envelope_id>
#
# PROFILE_A, PROFILE_B and PROFILE_F are the AWS CLI profiles for Hospital A, Hospital B and the Flower
# account. ssh runs with BatchMode, so load the host's key into ssh-agent first.
#
#   a. Hospital B stopped; a rogue in Hospital A's account claims Hospital B and signs with A's
#      key (rogue-task.sh B): it is refused (invalid_proof), the run fails closed, the hub says
#      'failed', and the server stays idle.
#   b. B still stopped, no rogue: only A connects, so Flower's sampling threshold (2 clients) is
#      never met. The run fails after the server's CLIENT_WAIT_TIMEOUT_SECONDS (default 300),
#      the hub says 'failed', and the server stays idle.
#   c. B started again: the A+B run completes and the hub says 'completed'.
#   Throughout: the same Flower server task (Flower account) and the same hub container.
#
# Before: this branch on the host and in the server image; Flower server, A and B at desired_count 1;
# the envelope selected and bound. Needs aws, terraform (rogue-task.sh), jq, ssh. About 25 minutes.
# Prints no secrets: ids, statuses and event reasons only.
set -euo pipefail
export AWS_PAGER=""

EID="${1:-}"
[[ -n "${EID}" && -n "${HOST:-}" ]] || { echo "usage: HOST=ubuntu@<host> PROFILE_A=.. PROFILE_B=.. PROFILE_F=.. $0 <envelope_id>" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARTICIPANT_DIR="${PARTICIPANT_DIR:-${HERE}/../participant}"
REGION="${REGION:-eu-west-2}"
CLUSTER="${CLUSTER:-openhealth-l1b}"
PROFILE_A="${PROFILE_A:?set PROFILE_A to the AWS CLI profile for Hospital A}"
PROFILE_B="${PROFILE_B:?set PROFILE_B to the AWS CLI profile for Hospital B}"
PROFILE_F="${PROFILE_F:?set PROFILE_F to the AWS CLI profile for the Flower account}"
CLIENT_WAIT_S="${CLIENT_WAIT_S:-300}"  # must match the server's CLIENT_WAIT_TIMEOUT_SECONDS
RUN_ID="${RUN_ID:-local-pathmnist-ab-001}"
FLOWER_URL="${FLOWER_URL:-http://flower-server.flower.openhealth.internal:8081}"
RUNS="${RUNS:-openhealth-cdi/src/vfp-governance/verifier/vault/runs}"  # on the host, from ~

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ host side (ssh)
on_host() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    "${HOST}" "$(printf '%q ' "$@")"
}
hub_get() { on_host curl -sf --max-time 10 "http://127.0.0.1:8080$1"; }
hub_post() {
  if [[ -n "${2:-}" ]]; then
    on_host curl -sf --max-time 10 -X POST -H 'content-type: application/json' -d "$2" "http://127.0.0.1:8080$1"
  else
    on_host curl -sf --max-time 10 -X POST "http://127.0.0.1:8080$1"
  fi
}
hub_state() { hub_get "/experiments/${RUN_ID}/status" | jq -r '.status // empty'; }
flower_status() { on_host curl -sf --max-time 10 "${FLOWER_URL}/status"; }
vault() { on_host sudo cat "${RUNS}/$1"; }

# ------------------------------------------------------------------ AWS side (profiles)
profile() { case "$1" in A) echo "${PROFILE_A}" ;; B) echo "${PROFILE_B}" ;; F) echo "${PROFILE_F}" ;; esac; }
ecs() { local who="$1"; shift; aws ecs "$@" --profile "$(profile "${who}")" --region "${REGION}" --cluster "${CLUSTER}"; }
service_task() { ecs "$1" list-tasks --service-name "$2" --desired-status RUNNING --query 'taskArns[0]' --output text; }
set_count() {
  ecs "$1" update-service --service "$2" --desired-count "$3" --query 'service.desiredCount' --output text >/dev/null
  aws ecs wait services-stable --profile "$(profile "$1")" --region "${REGION}" --cluster "${CLUSTER}" --services "$2"
}

# A task is ready once its client has reached the Flower connection loop (and not yet finished a run).
wait_connecting() {
  local who="$1" container="$2" task="${3:-}" found="" _
  for _ in $(seq 120); do
    [[ -n "${3:-}" ]] || task="$(service_task "${who}" "${container}" 2>/dev/null || true)"
    if [[ "${task}" == arn:* || "${task}" =~ ^[0-9a-f]{32}$ ]]; then
      found="$(aws logs filter-log-events --profile "$(profile "${who}")" --region "${REGION}" \
        --log-group-name "/ecs/${CLUSTER}" --log-stream-names "${container}/${container}/${task##*/}" \
        --filter-pattern '?"attempting Flower connection" ?"Flower client completed"' \
        --query 'events[].message' --output text 2>/dev/null || true)"
      if [[ "${found}" == *"attempting Flower connection"* && "${found}" != *"Flower client completed"* ]]; then
        echo "  ${container} task ${task##*/} is connecting to Flower"
        return 0
      fi
    fi
    sleep 5
  done
  fail "${container} (${who}) did not reach its Flower connection within 10 minutes"
}

# ------------------------------------------------------------------ one run through the hub
run_round() {
  local previous status start
  previous="$(flower_status | jq -r '.model_run_id // empty')"
  hub_post /experiments/initialise "$(jq -nc --arg run "${RUN_ID}" '{run_id: $run, rounds: 1}')" >/dev/null
  for _ in $(seq 60); do
    status="$(hub_get "/experiments/${RUN_ID}/status" || true)"
    [[ "$(jq -r '.can_start // false' <<<"${status}" 2>/dev/null)" == "true" ]] && break
    sleep 3
  done
  [[ "$(jq -r '.can_start // false' <<<"${status}")" == "true" \
     && "$(jq -r '.active_envelope_id // empty' <<<"${status}")" == "${EID}" ]] \
    || fail "Not start-ready: $(jq -c '{status, active_envelope_id, backend_bound, registered_clients}' <<<"${status}")"
  [[ "$(hub_post "/experiments/${RUN_ID}/start" | jq -r '.status // empty')" == "running" ]] || fail "START refused"
  start="$(date +%s)"
  while true; do
    HUB_STATE="$(hub_state || true)"
    [[ "${HUB_STATE}" == "completed" || "${HUB_STATE}" == "failed" ]] && break
    (( $(date +%s) - start < 1800 )) || fail "The hub still says '${HUB_STATE}' 30 minutes after START"
    sleep 5
  done
  ELAPSED=$(( $(date +%s) - start ))
  FLOWER="$(flower_status)"
  RUN="$(jq -r '.model_run_id // empty' <<<"${FLOWER}")"
  [[ -n "${RUN}" && "${RUN}" != "${previous}" ]] || fail "No new run on the Flower server (model_run_id ${RUN:-none})"
  EVENTS="$(vault "${RUN}/events.jsonl")"
  echo "  run ${RUN}: hub '${HUB_STATE}' ${ELAPSED} s after START; Flower '$(jq -r '.training.status' <<<"${FLOWER}")'" \
    "$(jq -r '.training.error // ""' <<<"${FLOWER}")"
}
has_event() { jq -se --arg t "$1" 'any(.[]; .event_type == $t)' <<<"${EVENTS}" >/dev/null; }

failed_and_idle() {
  [[ "${HUB_STATE}" == "failed" ]] || fail "The hub reports '${HUB_STATE}', not 'failed'"
  [[ "$(jq -r '.training.status' <<<"${FLOWER}")" == "error" ]] || fail "Flower reports $(jq -c '.training.status' <<<"${FLOWER}")"
  ! has_event round_fit_aggregated || fail "A round was aggregated"
  sleep 30
  local now
  now="$(flower_status)"
  [[ "$(jq -r '.model_run_id' <<<"${now}")" == "${RUN}" && "$(jq -r '.training.status' <<<"${now}")" == "error" \
     && "$(hub_state)" == "failed" ]] \
    || fail "Not idle 30 s later: Flower $(jq -c '{model_run_id, status: .training.status}' <<<"${now}"), hub '$(hub_state)'"
  pass "The hub says 'failed' (not 'completed'); nothing aggregated; 30 s later no new run, the server idle"
}

ROGUE_TASK=""
B_COUNT=""
cleanup() {
  # Every rogue this script may have started (rogue-task.sh tags them), not only the last one.
  local task
  for task in ${ROGUE_TASK} $(ecs A list-tasks --started-by issue7-rogue --query 'taskArns[]' --output text 2>/dev/null); do
    ecs A stop-task --task "${task}" --query 'task.lastStatus' --output text >/dev/null 2>&1 \
      || echo "Could not stop rogue ${task##*/}: aws ecs stop-task --profile ${PROFILE_A} --region ${REGION} --cluster ${CLUSTER} --task ${task##*/}" >&2
  done
  if [[ -n "${B_COUNT}" ]]; then
    if ecs B update-service --service flower-client-b --desired-count "${B_COUNT}" --query 'service.desiredCount' \
      --output text >/dev/null 2>&1; then
      echo "Hospital B's service back at desired_count ${B_COUNT}"
    else
      echo "Could not restore Hospital B: aws ecs update-service --profile ${PROFILE_B} --region ${REGION} --cluster ${CLUSTER} --service flower-client-b --desired-count ${B_COUNT}" >&2
    fi
  fi
}
trap cleanup EXIT

step "0. Preflight"
for tool in aws terraform jq ssh; do command -v "${tool}" >/dev/null || fail "${tool} is not installed"; done
[[ -d "${PARTICIPANT_DIR}" ]] || fail "No ${PARTICIPANT_DIR} (set PARTICIPANT_DIR to the participant root)"
hub_get /openapi.json | jq -e '.paths | has("/experiments/{run_id}/fail")' >/dev/null \
  || fail "The hub on ${HOST} has no /experiments/{run_id}/fail: deploy this branch first"
BOUND="$(flower_status | jq -c '{envelope: .bound_envelope.envelope_id, keys: (.bound_envelope.participant_keys // {} | keys), status: .training.status}')"
[[ "$(jq -r .envelope <<<"${BOUND}")" == "${EID}" ]] || fail "Flower is bound to $(jq -r .envelope <<<"${BOUND}"), not ${EID}"
[[ "$(jq -c .keys <<<"${BOUND}")" == '["org://HospitalA","org://HospitalB"]' ]] || fail "Bound keys: $(jq -c .keys <<<"${BOUND}")"
[[ "$(jq -r .status <<<"${BOUND}")" != "running" ]] || fail "Flower is already running a job"
F_TASK="$(service_task F flower-server)"
[[ "${F_TASK}" == arn:* ]] || fail "No running Flower server task in ${PROFILE_F}"
F_STARTED="$(ecs F describe-tasks --tasks "${F_TASK}" --query 'tasks[0].startedAt' --output text)"
HUB_STARTED="$(on_host docker inspect --format '{{.State.StartedAt}}' fc-hub)"
B_COUNT="$(ecs B describe-services --services flower-client-b --query 'services[0].desiredCount' --output text)"
wait_connecting A flower-client-a
pass "Hub up to date; Flower bound to ${EID} with keys for A and B; server task ${F_TASK##*/}; A connecting"

step "a. Hospital B stopped, a rogue in A's account claims B: refused, the run fails closed"
set_count B flower-client-b 0
echo "  Hospital B's service at 0"
ROGUE_OUT="$(cd "${PARTICIPANT_DIR}" && TF_WORKSPACE=a bash "${HERE}/rogue-task.sh" B)"
ROGUE_TASK="$(sed -n 's/^Started rogue \([0-9a-f]*\) .*/\1/p' <<<"${ROGUE_OUT}")"
[[ -n "${ROGUE_TASK}" ]] || fail "rogue-task.sh: ${ROGUE_OUT}"
echo "  rogue task ${ROGUE_TASK} (Hospital A's account, claims Hospital B, A's key)"
wait_connecting A flower-client-a "${ROGUE_TASK}"
wait_connecting A flower-client-a
run_round
REFUSED="$(jq -sc '[.[] | select(.event_type == "flower_client_rejected") | .reason] | unique' <<<"${EVENTS}")"
echo "  refused: ${REFUSED}"
jq -e 'index("invalid_proof:org://HospitalB")' <<<"${REFUSED}" >/dev/null || fail "The rogue claiming B was not refused"
has_event round_admission_failed || fail "No round_admission_failed event"
jq -se '[.[] | select(.event_type == "round_admission_failed")][0].admitted == ["org://HospitalA"]' <<<"${EVENTS}" >/dev/null \
  || fail "Hospital A was not the one proven organisation in the failed round"
pass "a: the rogue claiming Hospital B was refused (invalid_proof) and the round failed closed"
failed_and_idle

step "b. Hospital B missing, no rogue: the run fails in bounded time"
ecs A stop-task --task "${ROGUE_TASK}" --query 'task.lastStatus' --output text >/dev/null 2>&1 || true
ecs A wait tasks-stopped --tasks "${ROGUE_TASK}" || fail "The rogue task ${ROGUE_TASK} did not stop"
ROGUE_TASK=""
wait_connecting A flower-client-a
run_round
has_event round_clients_missing || fail "No round_clients_missing event: $(jq -sc '[.[] | .event_type]' <<<"${EVENTS}")"
MISSING="$(jq -sc '[.[] | select(.event_type == "round_clients_missing")][0] | {connected, required}' <<<"${EVENTS}")"
WAITED="$(jq -s '[.[] | select(.event_type == "round_fit_configured" or .event_type == "round_clients_missing")
  | .timestamp | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601] | .[1] - .[0]' <<<"${EVENTS}")"
echo "  ${MISSING}; the round waited ${WAITED} s for clients"
[[ "$(jq -r .connected <<<"${MISSING}")" == "1" ]] || fail "Expected exactly one connected client: ${MISSING}"
(( WAITED >= CLIENT_WAIT_S - 5 && WAITED <= CLIENT_WAIT_S + 30 )) || fail "Waited ${WAITED} s, expected about ${CLIENT_WAIT_S} s"
(( ELAPSED <= CLIENT_WAIT_S + 90 )) || fail "The hub said 'failed' only ${ELAPSED} s after START"
pass "b: Hospital B never connected; the run failed after ${WAITED} s (${ELAPSED} s after START)"
failed_and_idle

step "c. Hospital B back: the A+B run completes"
set_count B flower-client-b 1
wait_connecting B flower-client-b
wait_connecting A flower-client-a
run_round
[[ "${HUB_STATE}" == "completed" ]] || fail "The hub reports '${HUB_STATE}': $(jq -r '.training.error // ""' <<<"${FLOWER}")"
ADMITTED="$(jq -sc '[.[] | select(.event_type == "round_clients_admitted") | .participants]' <<<"${EVENTS}")"
[[ "${ADMITTED}" == '[["org://HospitalA","org://HospitalB"]]' ]] || fail "Admitted ${ADMITTED}"
PARTICIPANTS="$(vault "${RUN}/participants.json" | jq -c '[.participants[].participant_id] | sort')"
[[ "${PARTICIPANTS}" == '["org://HospitalA","org://HospitalB"]' ]] || fail "participants.json lists ${PARTICIPANTS}"
ROUNDS="$(vault "${RUN}/final_model_metadata.json" | jq -r '.rounds_completed')"
[[ "${ROUNDS}" == "1" ]] || fail "rounds_completed=${ROUNDS}"
pass "c: admitted exactly A and B, rounds_completed 1, the hub says 'completed'"

step "Nothing restarted"
[[ "$(service_task F flower-server)" == "${F_TASK}" \
   && "$(ecs F describe-tasks --tasks "${F_TASK}" --query 'tasks[0].startedAt' --output text)" == "${F_STARTED}" ]] \
  || fail "The Flower server task changed or restarted"
[[ "$(on_host docker inspect --format '{{.State.StartedAt}}' fc-hub)" == "${HUB_STARTED}" ]] || fail "The hub container restarted"
pass "Same Flower server task ${F_TASK##*/} (started ${F_STARTED}) and the same hub container throughout"

echo
echo "=== Test1F on L1-B1 (a, b, c): PASS ==="

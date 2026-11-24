#!/usr/bin/env bash
# Single-hospital run (quorum of one) on the five accounts, run on the governance host from ~/openhealth-cdi.
# An optional diagnostic, not an L1-B2 acceptance test: A+B (min_clients 2) is the execution baseline.
#
#   bash ~/quorum1-b2.sh <envelope_id>
#
# Before: Flower server and Hospital A's client at desired_count 1, B's and C's clients at 0 (so Flower can only
# sample A); the envelope selected. Initialises a 3-round AB_BASE run with min_clients 1 through the hub, starts
# it, and checks that every round admitted only org://HospitalA and that all 3 rounds completed.
set -euo pipefail
trap 'echo "=== Quorum of one: FAIL (command failed at line ${LINENO}) ===" >&2' ERR

EID="${1:?usage: $0 <envelope_id>}"
H=http://127.0.0.1:8080
RUN=local-pathmnist-ab-001   # the clients register under this run id; a new id would leave 0 registered
FU=http://flower-server.flower.openhealth.internal:8081
ROUNDS=3
cd ~/openhealth-cdi

sel="$(curl -fsS "${H}/administration/envelopes" | jq -r .selected_envelope_id)"
[[ "${sel}" == "${EID}" ]] || { echo "=== Quorum of one: FAIL (selected envelope is ${sel}, not ${EID}: select it first) ==="; exit 1; }

curl -fsS -X POST -H 'content-type: application/json' \
  -d "{\"run_id\":\"${RUN}\",\"phase\":\"AB_BASE\",\"rounds\":${ROUNDS},\"min_clients\":1}" \
  "${H}/experiments/initialise" | jq -c '{status, run_id, backend_bound}'
for _ in $(seq 36); do
  [[ "$(curl -fsS "${H}/experiments/${RUN}/status" | jq -r .can_start)" == true ]] && break
  sleep 5
done
st="$(curl -fsS "${H}/experiments/${RUN}/status")"; echo "${st}" | jq -c '{can_start, min_clients}'
[[ "$(echo "${st}" | jq -r .min_clients)" == 1 ]] \
  || { echo "=== Quorum of one: FAIL (hub min_clients is $(echo "${st}" | jq -r .min_clients), not 1) ==="; exit 1; }
before="$(curl -fsS --max-time 10 "${FU}/status" | jq -r .model_run_id)"
date -u +'START %H:%M:%SZ'
curl -fsS -X POST "${H}/experiments/${RUN}/start" | jq -c '{status}' \
  || { echo "=== Quorum of one: FAIL (start refused) ==="; exit 1; }
for _ in $(seq 120); do
  hub="$(curl -fsS --max-time 10 "${H}/experiments/${RUN}/status" | jq -r .status || true)"
  [[ "${hub}" == completed || "${hub}" == failed ]] && break
  sleep 10
done
date -u +"END %H:%M:%SZ, hub: ${hub}"

# After the run, missing evidence is reported by the detailed FAIL line below, not by the trap.
status="$(curl -fsS --max-time 10 "${FU}/status" || echo '{}')"
echo "${status}" | jq -c '{model_run_id, status: .training.status, round: .training.round, error: .training.error}'
V="src/vfp-governance/verifier/vault/runs/$(echo "${status}" | jq -r .model_run_id)"
sudo cat "${V}/events.jsonl" | jq -c 'select(.event_type | test("round_clients|flower_client_rejected|round_admission_failed|quorum")) | {e: .event_type, round, participants, required, reason}' || true
final="$(sudo cat "${V}/final_model_metadata.json" | jq -c '{status, rounds_completed}' || true)"
echo "final: ${final}"

# Every admitted round is exactly [A], and there are ROUNDS of them.
only_a="$(sudo cat "${V}/events.jsonl" | jq -s --argjson n "${ROUNDS}" \
  '[.[] | select(.event_type == "round_clients_admitted")] | (length == $n) and all(.participants == ["org://HospitalA"])' || true)"
rejected="$(sudo cat "${V}/events.jsonl" | jq -s '[.[] | select(.event_type == "flower_client_rejected")] | length' || true)"
if [[ "${hub}" == completed && "${only_a}" == true ]] && [[ "$(echo "${final}" | jq -r .rounds_completed)" == "${ROUNDS}" ]] \
   && [[ "$(echo "${status}" | jq -r .model_run_id)" != "${before}" ]] && [[ "${rejected}" == 0 ]]; then
  echo "=== Quorum of one: PASS ==="
else
  echo "=== Quorum of one: FAIL (hub ${hub}, only A every round: ${only_a}, new run: $([[ "$(echo "${status}" | jq -r .model_run_id)" != "${before}" ]] && echo yes || echo no), clients refused: ${rejected}) ==="
  exit 1
fi

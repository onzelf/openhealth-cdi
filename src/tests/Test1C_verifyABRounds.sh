#!/usr/bin/env bash
# Verify the completed AB_BASE Flower run and its central-evaluation artefacts.
#
# Usage:
#   ./Test1C_verifyABRounds.sh [run_id] [expected_rounds]
#
# Defaults:
#   run_id          = local-pathmnist-ab-001
#   expected_rounds = 10
set -euo pipefail

RUN_ID="${1:-local-pathmnist-ab-001}"
EXPECTED_ROUNDS="${2:-10}"
RUN_DIR="/vault/runs/${RUN_ID}"

echo "Usage: $0 [run_id] [expected_rounds]"
echo "Input arguments: run_id=${RUN_ID} expected_rounds=${EXPECTED_ROUNDS}"
echo

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
pass() { printf "\033[32m✓\033[0m %s\n" "$*"; }
fail() { printf "\033[31m✗\033[0m %s\n" "$*"; exit 1; }

docker ps -a --format '{{.Names}}' | grep -qx flower-server \
  || fail "Missing flower-server container"

for client in flower-client-a flower-client-b; do
  client_log="$(docker logs "$client" 2>&1 || true)"

  grep -F "CUDA ready:" >/dev/null <<< "$client_log" \
    || fail "$client did not report CUDA ready"

  grep -F "torch=2.2.0+cu121" >/dev/null <<< "$client_log" \
    || fail "$client did not report torch 2.2.0+cu121"

  grep -F "device=cuda" >/dev/null <<< "$client_log" \
    || fail "$client did not load partition on CUDA"

  pass "$client reported CUDA runtime"
done
pass "Hospital A and B clients trained with the validated CUDA stack"

for file in \
  model.pt \
  metrics.csv \
  participants.json \
  confusion_counts.csv \
  confusion_normalized.csv \
  class_metrics.csv \
  final_model_metadata.json
do
  docker exec flower-server test -s "${RUN_DIR}/${file}" \
    || fail "Missing or empty ${RUN_DIR}/${file}"
done
pass "AB_BASE artefacts exist"

rows="$(
  docker exec -i flower-server python - "${RUN_DIR}/metrics.csv" <<'PY'
import csv
import sys

with open(sys.argv[1], newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))
print(len(rows))
PY
)"
EXPECTED_ROUNDS__=$((EXPECTED_ROUNDS + 1))
[[ "${rows}" == "${EXPECTED_ROUNDS__}" ]] \
  || fail "Expected ${EXPECTED_ROUNDS__} central metric rows, found ${rows}"
pass "Central metrics include round 0 baseline plus ${EXPECTED_ROUNDS} trained rounds"

docker exec -i flower-server python - \
  "${RUN_DIR}/metrics.csv" \
  "${RUN_DIR}/class_metrics.csv" \
  "${RUN_DIR}/participants.json" <<'PY'
import csv
import json
import sys

metrics_path, classes_path, participants_path = sys.argv[1:]

with open(metrics_path, newline="", encoding="utf-8") as handle:
    metrics = list(csv.DictReader(handle))
assert metrics, "metrics.csv is empty"
required = {
    "accuracy",
    "macro_recall",
    "non_cancer_recall",
    "cancer_recall",
    "cancer_f1",
    "class_7_recall",
    "class_8_recall",
}
assert required.issubset(metrics[-1]), required - set(metrics[-1])

with open(classes_path, newline="", encoding="utf-8") as handle:
    classes = {
        int(row["class_id"]): row
        for row in csv.DictReader(handle)
    }
assert int(classes[2]["support"]) == 0, "label 2 must be unavailable"
assert int(classes[7]["support"]) > 0
assert int(classes[8]["support"]) > 0

with open(participants_path, encoding="utf-8") as handle:
    payload = json.load(handle)
participants = {
    item["participant_id"]
    for item in payload["participants"]
}
assert participants == {"org://HospitalA", "org://HospitalB"}, participants

print("\nFinal central metrics:")
for name in sorted(required):
    print(f"  {name}={metrics[-1][name]}")
PY

pass "Participants and unavailable label 2 verified"

status="$(
  docker exec -i fc-hub python - <<'PY2'
import json
from urllib.request import urlopen

with urlopen("http://flower-server:8081/status", timeout=5) as r:
    print(r.read().decode())
PY2
)"
printf '%s\n' "${status}" | grep -F '"status":"done"' >/dev/null \
  || printf '%s\n' "${status}" | grep -F '"status": "done"' >/dev/null \
  || fail "Flower /status does not report training done"
pass "Flower control plane reports training done"

echo
echo "AB_BASE verification completed for run ${RUN_ID}"

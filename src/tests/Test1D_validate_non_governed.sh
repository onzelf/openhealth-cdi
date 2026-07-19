#!/usr/bin/env bash
# Direct prediction validation for the protected AB_BASE model artefact.
# This is NOT a governed query test.
# It loads model.pt directly and evaluates selected labels as a regular FL model.

set -euo pipefail

RUN_ID="${1:-local-pathmnist-ab-001}"
RUN_DIR="/vault/runs/${RUN_ID}"
MODEL_PATH="${RUN_DIR}/model.pt"

pass() { printf "\033[32m✓\033[0m %s\n" "$*"; }
fail() { printf "\033[31m✗\033[0m %s\n" "$*"; exit 1; }

docker ps -a --format '{{.Names}}' | grep -qx flower-server \
  || fail "Missing flower-server container"

docker exec flower-server test -s "${MODEL_PATH}" \
  || fail "Missing or empty model artefact: ${MODEL_PATH}"

echo
echo "Direct prediction validation for AB_BASE model"
echo "Run: ${RUN_ID}"
echo "Model: ${MODEL_PATH}"
echo

docker exec -i flower-server python - "${MODEL_PATH}" <<'PY'
import json
import sys

import numpy as np
import torch
from torch.utils.data import DataLoader, Subset

from pathmnist.common import (
    CLASS_NAMES,
    IGNORED_CLASSES,
    Net,
    load_test_dataset,
    labels_array,
)

model_path = sys.argv[1]

# Direct model validation targets.
# No governance filtering is applied here.
target_labels = [1, 2, 3, 7, 8]

# Smoke-test expectations for AB_BASE.
# Labels 1 and 3 should be good.
# Labels 7 and 8 should remain weak because A+B have little cancer data.
expectations = {
    1: ("high", 0.75, None),
    3: ("high", 0.75, None),
    7: ("low", None, 0.10),
    8: ("weak", None, 0.65),
}

reserved = set(int(x) for x in IGNORED_CLASSES)

model = Net()
state = torch.load(model_path, map_location="cpu")

# Accept either a raw state_dict or a checkpoint wrapper.
if isinstance(state, dict) and "model_state_dict" in state:
    state = state["model_state_dict"]

model.load_state_dict(state)
model.eval()

dataset = load_test_dataset()
labels = labels_array(dataset)

results = []

for label in target_labels:
    if label in reserved:
        results.append({
            "label": label,
            "name": CLASS_NAMES[label],
            "status": "ERROR",
            "reason": "label is outside the trained/evaluable AB_BASE scope",
        })
        continue

    indices = np.flatnonzero(labels == label)
    if len(indices) == 0:
        results.append({
            "label": label,
            "name": CLASS_NAMES[label],
            "status": "ERROR",
            "reason": "no test samples found",
        })
        continue

    loader = DataLoader(Subset(dataset, indices.tolist()), batch_size=128, shuffle=False)

    correct = 0
    total = 0
    pred_counts = {}

    with torch.no_grad():
        for x, y in loader:
            logits = model(x)
            pred = torch.argmax(logits, dim=1).cpu().numpy()

            y_np = np.asarray(y).reshape(-1).astype(int)
            total += len(y_np)
            correct += int((pred == y_np).sum())

            for p in pred:
                pred_counts[int(p)] = pred_counts.get(int(p), 0) + 1

    recall = correct / total if total else 0.0

    status = "OK"
    kind, min_expected, max_expected = expectations[label]

    if min_expected is not None and recall < min_expected:
        status = "FAIL"
    if max_expected is not None and recall > max_expected:
        status = "FAIL"

    top_predictions = sorted(
        pred_counts.items(),
        key=lambda kv: kv[1],
        reverse=True,
    )[:5]

    results.append({
        "label": label,
        "name": CLASS_NAMES[label],
        "status": status,
        "expectation": kind,
        "recall": recall,
        "total_samples": total,
        "top_predicted_labels": [
            {
                "label": int(pred_label),
                "name": CLASS_NAMES[int(pred_label)],
                "count": int(count),
            }
            for pred_label, count in top_predictions
        ],
    })

print(json.dumps({
    "validation": "direct_ab_base_model_prediction",
    "governance_decision": "not_used",
    "model_path": model_path,
    "target_labels": target_labels,
    "reserved_labels": sorted(reserved),
    "results": results,
}, indent=2))

# Assertions for smoke test.
by_label = {item["label"]: item for item in results}

assert by_label[2]["status"] == "ERROR", "label 2 must be outside trained/evaluable scope"

for label in [1, 3, 7, 8]:
    assert by_label[label]["status"] == "OK", (
        f"label {label} failed direct AB_BASE expectation: {by_label[label]}"
    )

print()
print("Direct AB_BASE model prediction validation passed")
PY

pass "Direct model prediction works for labels 1,3,7,8"
pass "Label 2 correctly errors because it is outside the trained/evaluable scope"

echo
echo "Direct prediction validation completed for run ${RUN_ID}"


# ENVELOPE_ID="2e1bc0e4-ee34-4fcd-85f4-a68534ac9fcb"


ENVELOPE_ID="${1:-}"

[[ -n "${ENVELOPE_ID}" ]] || {
  echo "Usage: $0 <active-envelope-id>" >&2
  exit 1
}


docker exec -i \
  -e ENVELOPE_ID="${ENVELOPE_ID}" \
  flower-server python3 - <<'PY'
import base64
import io
import json
import os

import numpy as np
import requests
from medmnist import PathMNIST
from PIL import Image

from pathmnist.common import CLASS_NAMES, DATA_ROOT


TARGET_LABEL = 3

dataset = PathMNIST(
    root=str(DATA_ROOT),
    split="test",
    download=True,
)

labels = np.asarray(dataset.labels, dtype=np.int64).reshape(-1)
SAMPLE_INDEX = int(np.flatnonzero(labels == TARGET_LABEL)[0])
#image, label = dataset[sample_index]


RUN_ID = "local-pathmnist-ab-001"
#SAMPLE_INDEX = 35
URL = "http://127.0.0.1:8081/predict_image"

envelope_id = os.environ["ENVELOPE_ID"]

# Load the same deterministic PathMNIST test sample used previously.
dataset = PathMNIST(
    root=str(DATA_ROOT),
    split="test",
    download=True,
)

image, label = dataset[SAMPLE_INDEX]
actual_label = int(np.asarray(label).reshape(-1)[0])

if not isinstance(image, Image.Image):
    image = Image.fromarray(np.asarray(image))

buffer = io.BytesIO()
image.convert("RGB").save(buffer, format="PNG")
image_b64 = base64.b64encode(buffer.getvalue()).decode("ascii")

request_body = {
    "envelope_id": envelope_id,
    "run_id": RUN_ID,
    "filename": f"pathmnist-test-{SAMPLE_INDEX}.png",
    "image_b64": image_b64,
    "topk": 3,
}

print("Request:")
print(json.dumps({
    "envelope_id": envelope_id,
    "run_id": RUN_ID,
    "filename": request_body["filename"],
    "sample_index": SAMPLE_INDEX,
    "actual_label": actual_label,
    "actual_tissue": CLASS_NAMES[actual_label],
    "image_bytes": len(buffer.getvalue()),
}, indent=2))

response = requests.post(
    URL,
    json=request_body,
    timeout=30,
)

print(f"\nHTTP status: {response.status_code}")

try:
    body = response.json()
except Exception:
    print(response.text)
    raise

print("\nResponse:")
print(json.dumps(body, indent=2))

response.raise_for_status()

assert body["run_id"] == RUN_ID
assert body["envelope_id"] == envelope_id
assert body["filename"] == request_body["filename"]
assert body["input_image"]["model_width"] == 28
assert body["input_image"]["model_height"] == 28
assert body["input_image"]["model_mode"] == "RGB"
assert isinstance(body["prediction_label"], int)
assert body["prediction_tissue"]
assert len(body["topk"]) == 3
assert body["topk"][0]["label"] == body["prediction_label"]
assert body["topk"][0]["tissue"] == body["prediction_tissue"]

print("\nEvidence:")
print(f"  dataset actual : {actual_label} — {CLASS_NAMES[actual_label]}")
print(
    f"  model predicted: "
    f"{body['prediction_label']} — {body['prediction_tissue']}"
)
print("✓ /predict_image direct inference test passed")
PY

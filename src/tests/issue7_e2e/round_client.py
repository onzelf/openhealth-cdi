#!/usr/bin/env python3
"""A Flower client for round_probe.py that answers the challenge with the real
flower_client/client.py code. Args: <repo-root> <address> <params.npz> <org_id> <key hex or ''>."""

import importlib.util
import os
import platform
import sys
import time
import warnings
from pathlib import Path

# Flower's telemetry thread calls platform.architecture(), which forks `file`; on macOS a
# fork while gRPC is running can hang the client for good.
platform.architecture = lambda *a, **k: ("64bit", "")

warnings.filterwarnings("ignore")
root, address, npz, org_id, key_hex = sys.argv[1:6]
os.environ["ORG_ID"] = org_id
os.environ["EXECUTION_KEY_HEX"] = key_hex
os.environ.pop("EXECUTION_KEY_FILE", None)
backend = Path(root) / "src" / "vfp-core" / "backend"
sys.path.insert(0, str(backend))
spec = importlib.util.spec_from_file_location("real_client", backend / "flower_client" / "client.py")
real = importlib.util.module_from_spec(spec)
spec.loader.exec_module(real)

import flwr as fl  # noqa: E402
import numpy as np  # noqa: E402

data = np.load(npz, allow_pickle=False)
arrays = [data[k] for k in data.files]


class ProbeClient(fl.client.NumPyClient):
    def get_properties(self, config):
        return real.FlowerClient.get_properties(self, config)

    def get_parameters(self, config):
        return arrays

    fits = 0

    def fit(self, parameters, config):
        # Test hook: FAIL_ON_FIT=N makes this client fail its Nth fit (a client dropping mid-run).
        ProbeClient.fits += 1
        if os.getenv("FAIL_ON_FIT") and ProbeClient.fits == int(os.getenv("FAIL_ON_FIT")):
            raise RuntimeError("probe client failing this round on purpose")
        return arrays, 10, {"train_loss": 0.5, "train_accuracy": 0.5}

    def evaluate(self, parameters, config):
        return 0.0, 10, {}


while True:  # like the real client, retry until the server's gRPC port is open
    try:
        fl.client.start_numpy_client(server_address=address, client=ProbeClient())
        break
    except Exception:
        time.sleep(1)

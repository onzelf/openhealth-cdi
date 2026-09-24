#!/usr/bin/env python3
"""Checks the client and server reach PathMNIST through the workload seam."""

from __future__ import annotations

import ast
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1] / "vfp-core" / "backend"
sys.path.insert(0, str(BACKEND))

from workloads import REQUIRED_NAMES  # noqa: E402

CLIENT = BACKEND / "flower_client" / "client.py"
SERVER = BACKEND / "flower_server" / "server.py"


def imported_names(path: Path, module: str) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.ImportFrom) and node.module == module:
            names.update(alias.name for alias in node.names)
    return names


def run(code: str, workload: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=str(BACKEND), WORKLOAD=workload)
    return subprocess.run(
        [sys.executable, "-c", code], env=env, capture_output=True, text=True
    )


def main() -> None:
    client = imported_names(CLIENT, "workloads.active")
    server = imported_names(SERVER, "workloads.active")
    assert client and server
    assert not imported_names(CLIENT, "pathmnist.common")
    assert not imported_names(SERVER, "pathmnist.common")
    assert client | server == set(REQUIRED_NAMES)
    print("PASS: client and server import only through workloads.active")

    for bad in ("no-such-workload", "os"):
        result = run("import workloads.active", bad)
        assert result.returncode != 0
        assert "Unknown WORKLOAD" in result.stderr
    fake = (
        "import sys, types, workloads\n"
        "workloads.WORKLOADS['fake'] = 'fake'\n"
        "sys.modules['fake'] = types.ModuleType('fake')\n"
        "import workloads.active\n"
    )
    result = run(fake, "fake")
    assert result.returncode != 0
    assert "does not export required names" in result.stderr
    print("PASS: an unknown or incomplete workload stops start-up")

    try:
        import medmnist  # noqa: F401
        import torch  # noqa: F401
    except ImportError:
        print("SKIP: the identity check needs torch and medmnist")
        return
    os.environ.pop("WORKLOAD", None)
    os.environ.setdefault("MEDMNIST_ROOT", tempfile.mkdtemp())
    import pathmnist.common as original
    import workloads.active as active

    assert active.WORKLOAD == "pathmnist"
    for name in REQUIRED_NAMES:
        assert getattr(active, name) is getattr(original, name), name
    print("PASS: by default every name is PathMNIST's own object")


if __name__ == "__main__":
    main()

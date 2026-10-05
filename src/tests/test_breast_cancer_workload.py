#!/usr/bin/env python3
"""Checks the tabular Breast Cancer workload (needs torch and numpy)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1] / "vfp-core" / "backend"
sys.path.insert(0, str(BACKEND))


def main() -> None:
    try:
        import numpy as np
        import torch  # noqa: F401
    except ImportError as exc:
        print(f"SKIP: needs torch and numpy ({exc})")
        return

    os.environ["WORKLOAD"] = "breast_cancer"
    import workloads.active as active
    import workloads.breast_cancer_workload as w
    from workloads import REQUIRED_NAMES

    for name in REQUIRED_NAMES:
        assert getattr(active, name) is getattr(w, name), name

    _, labels = w._feature_rows()
    sites = w._row_indices_by_site()
    everything = np.concatenate([sites[k] for k in ("A", "B", "C", "test")])
    assert len(everything) == len(set(everything.tolist())) == len(labels)
    expected = np.bincount(labels, minlength=2) * (1 - w.TEST_FRACTION) / 3
    for site in ("A", "B", "C"):
        counts = np.bincount(labels[sites[site]], minlength=2)
        assert np.all(np.abs(counts - expected) <= 2), (site, counts)
    w._row_indices_by_site.cache_clear()
    again = w._row_indices_by_site()
    assert all(np.array_equal(sites[k], again[k]) for k in sites)
    print("PASS: the sites and test split are disjoint, complete, stratified")

    loader, counts = w.make_hospital_loader("A")
    batch, target = next(iter(loader))
    assert batch.shape[1] == w.NUM_FEATURES
    assert set(target.tolist()) <= {0, 1}
    assert sum(counts.values()) == len(loader.dataset)
    test_labels = w.labels_array(w.load_test_dataset())
    assert len(test_labels) == len(sites["test"])

    # Three sites, FedAvg, ten rounds.
    w.seed_everything()
    model = w.Net().to(w.DEVICE)
    loaders = [w.make_hospital_loader(site)[0] for site in ("A", "B", "C")]
    for _ in range(10):
        updates = []
        for loader in loaders:
            local = w.Net().to(w.DEVICE)
            w.set_parameters(local, w.get_parameters(model))
            w.train_one_round(local, loader)
            updates.append((w.get_parameters(local), len(loader.dataset)))
        total = sum(n for _, n in updates)
        averaged = [
            sum(params[i] * n for params, n in updates) / total
            for i in range(len(updates[0][0]))
        ]
        w.set_parameters(model, averaged)
    _, accuracy, _, recalls, confusion, _ = w.evaluate_full_test(
        model, w.make_test_loader()
    )
    assert confusion.shape == (2, 2) and len(recalls) == 2
    assert accuracy >= 0.90, accuracy
    print(f"PASS: 3 sites, FedAvg, 10 rounds: accuracy {accuracy:.3f}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Fast deterministic checks for the frozen PathMNIST partition logic."""

from __future__ import annotations

import os
from dataclasses import dataclass

os.environ.setdefault("TRAIN_FRACTION", "0.80")
os.environ.setdefault("CANCER_SAMPLES_PER_AB_HOSPITAL", "100")

import numpy as np

from pathmnist.common import (
    IGNORED_CLASSES,
    STORY_CANCER_CLASSES,
    STORY_NON_CANCER_CLASSES,
    hospital_counts,
    partition_indices,
)


@dataclass
class SyntheticDataset:
    labels: np.ndarray


def main() -> None:
    # Enough samples to exercise the exact A/B cancer cap and a C remainder.
    labels = []
    for label in STORY_NON_CANCER_CLASSES:
        labels.extend([label] * 1000)
    for label in STORY_CANCER_CLASSES:
        labels.extend([label] * 2000)
    for label in IGNORED_CLASSES:
        labels.extend([label] * 1000)

    dataset = SyntheticDataset(
        labels=np.asarray(labels, dtype=np.int64).reshape(-1, 1)
    )
    a = partition_indices(dataset, "A")
    b = partition_indices(dataset, "B")
    c = partition_indices(dataset, "C")

    assert set(a).isdisjoint(b)
    assert set(a).isdisjoint(c)
    assert set(b).isdisjoint(c)

    counts_a = hospital_counts(dataset, a)
    counts_b = hospital_counts(dataset, b)
    counts_c = hospital_counts(dataset, c)

    for ignored in IGNORED_CLASSES:
        assert counts_a[ignored] == 0
        assert counts_b[ignored] == 0
        assert counts_c[ignored] == 0

    for cancer in STORY_CANCER_CLASSES:
        assert counts_a[cancer] == 100
        assert counts_b[cancer] == 100
        assert counts_c[cancer] > 100

    for non_cancer in STORY_NON_CANCER_CLASSES:
        assert counts_a[non_cancer] > 0
        assert counts_b[non_cancer] > 0
        assert counts_c[non_cancer] == 0

    print("PASS: frozen PathMNIST A/B partition invariants")


if __name__ == "__main__":
    main()

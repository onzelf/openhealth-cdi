#!/usr/bin/env python3
"""Unit checks for story-level metric grouping."""

from __future__ import annotations

import numpy as np

NON_CANCER = [0, 2, 3, 4, 5, 6]
CANCER = [7, 8]


def main() -> None:
    recalls = np.asarray(
        [0.90, 0.00, 0.80, 0.70, 0.60, 0.50, 0.40, 0.20, 0.30]
    )
    f1 = np.asarray(
        [0.91, 0.00, 0.81, 0.71, 0.61, 0.51, 0.41, 0.25, 0.35]
    )

    non_cancer_recall = float(np.mean(recalls[NON_CANCER]))
    cancer_recall = float(np.mean(recalls[CANCER]))
    cancer_f1 = float(np.mean(f1[CANCER]))

    assert abs(non_cancer_recall - 0.65) < 1e-12
    assert abs(cancer_recall - 0.25) < 1e-12
    assert abs(cancer_f1 - 0.30) < 1e-12

    # Label 1 is not part of any story aggregate.
    altered = recalls.copy()
    altered[1] = 1.0
    assert float(np.mean(altered[NON_CANCER])) == non_cancer_recall
    assert float(np.mean(altered[CANCER])) == cancer_recall

    print("PASS: story metric groups exclude label 1")


if __name__ == "__main__":
    main()

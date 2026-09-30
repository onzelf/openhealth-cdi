#!/usr/bin/env python3
"""Rebuild breast_cancer.csv from the UCI original.

Source: UCI Machine Learning Repository, Breast Cancer Wisconsin (Diagnostic),
id 17, https://archive.ics.uci.edu/dataset/17 (CC BY 4.0).
wdbc.data columns: ID, diagnosis (M/B), then 30 measurements.
Output: the 30 measurements with names, then target (0 = malignant, 1 = benign).

    curl -LO "https://archive.ics.uci.edu/static/public/17/breast+cancer+wisconsin+diagnostic.zip"
    unzip breast+cancer+wisconsin+diagnostic.zip wdbc.data
    python3 make_breast_cancer_csv.py wdbc.data
"""
import csv
import hashlib
import sys
from pathlib import Path

WDBC_SHA256 = "d606af411f3e5be8a317a5a8b652b425aaf0ff38ca683d5327ffff94c3695f4a"
OUT = Path(__file__).resolve().parent / "breast_cancer.csv"

MEASURES = ["radius", "texture", "perimeter", "area", "smoothness", "compactness",
            "concavity", "concave_points", "symmetry", "fractal_dimension"]
COLUMNS = ([f"mean_{m}" for m in MEASURES] + [f"{m}_error" for m in MEASURES]
           + [f"worst_{m}" for m in MEASURES] + ["target"])
TARGET = {"M": 0, "B": 1}

data = Path(sys.argv[1]).read_bytes()
assert hashlib.sha256(data).hexdigest() == WDBC_SHA256, "not the expected wdbc.data"

with OUT.open("w", newline="") as f:
    out = csv.writer(f, lineterminator="\n")
    out.writerow(COLUMNS)
    for row in csv.reader(data.decode("ascii").splitlines()):
        out.writerow([repr(float(x)) for x in row[2:]] + [TARGET[row[1]]])

print(f"wrote {OUT.name}")

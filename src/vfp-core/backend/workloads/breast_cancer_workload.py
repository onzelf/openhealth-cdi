#!/usr/bin/env python3
"""Breast Cancer Wisconsin (Diagnostic): an experimental tabular workload.

569 rows, 30 features, 0 = malignant, 1 = benign. From the UCI original
(dataset 17, CC BY 4.0); data/make_breast_cancer_csv.py rebuilds the CSV.
Features are scaled on the whole dataset: fine for this public demo, not for
real site data.
"""

from __future__ import annotations

import os
import random
from functools import lru_cache
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, Dataset

SEED = 20260919
NUM_FEATURES = 30
NUM_CLASSES = 2
CLASS_NAMES = ["malignant", "benign"]  # 0 = malignant, 1 = benign
STORY_CANCER_CLASSES = [0]
STORY_NON_CANCER_CLASSES = [1]
IGNORED_CLASSES: set = set()
ACTIVE_CLASSES = STORY_NON_CANCER_CLASSES + STORY_CANCER_CLASSES

PARTITION_HOSPITALS = ("A", "B", "C")
TEST_FRACTION = 0.20

BATCH_SIZE = int(os.getenv("BC_BATCH_SIZE", "32"))
LOCAL_EPOCHS = int(os.getenv("BC_LOCAL_EPOCHS", "20"))
LEARNING_RATE = float(os.getenv("BC_LEARNING_RATE", "0.01"))

# Names the client and server still import. Values that fit this workload.
PATHMNIST_PARTITION_PROFILE = "BREAST_CANCER_STRATIFIED_ABC_V1"
PATHMNIST_PARTITION_SEED = SEED
CANCER_SAMPLES_PER_AB_HOSPITAL = 0  # not used by this workload

DEVICE = torch.device(
    os.getenv("DEVICE", "cuda" if torch.cuda.is_available() else "cpu")
)

_CSV_PATH = Path(__file__).resolve().parent / "data" / "breast_cancer.csv"


class TabularDataset(Dataset):
    """Standardised float rows, with ``labels`` like the image datasets."""

    def __init__(self, features: np.ndarray, labels: np.ndarray) -> None:
        self.features = torch.as_tensor(features, dtype=torch.float32)
        self.labels = np.asarray(labels, dtype=np.int64).reshape(-1, 1)

    def __len__(self) -> int:
        return len(self.features)

    def __getitem__(self, index: int) -> Tuple[torch.Tensor, int]:
        return self.features[index], int(self.labels[index, 0])


@lru_cache(maxsize=1)
def _read_csv() -> Tuple[np.ndarray, np.ndarray]:
    """The measurements exactly as published, and the labels."""

    table = np.loadtxt(_CSV_PATH, delimiter=",", skiprows=1, dtype=np.float64)
    return table[:, :NUM_FEATURES], table[:, NUM_FEATURES].astype(np.int64)


@lru_cache(maxsize=1)
def _feature_rows() -> Tuple[np.ndarray, np.ndarray]:
    features, labels = _read_csv()
    std = features.std(axis=0)
    std[std == 0] = 1.0
    # Scaled on the whole dataset: a demo shortcut (see the docstring).
    features = (features - features.mean(axis=0)) / std
    return features.astype(np.float32), labels


@lru_cache(maxsize=1)
def _row_indices_by_site() -> Dict[str, np.ndarray]:
    """Stratified test split, then a stratified three-way split of the rest."""

    _, labels = _feature_rows()
    rng = np.random.RandomState(SEED)
    parts: Dict[str, List[np.ndarray]] = {"test": []}
    for hospital in PARTITION_HOSPITALS:
        parts[hospital] = []

    for label in range(NUM_CLASSES):
        indices = rng.permutation(np.flatnonzero(labels == label))
        n_test = int(round(len(indices) * TEST_FRACTION))
        parts["test"].append(indices[:n_test])
        for hospital, chunk in zip(
            PARTITION_HOSPITALS,
            np.array_split(indices[n_test:], len(PARTITION_HOSPITALS)),
        ):
            parts[hospital].append(chunk)

    return {
        name: np.sort(np.concatenate(chunks)) for name, chunks in parts.items()
    }


def seed_everything(seed: int = SEED) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def transform() -> None:
    raise NotImplementedError("This workload has no image transform.")


def load_test_dataset() -> TabularDataset:
    features, labels = _feature_rows()
    rows = _row_indices_by_site()["test"]
    return TabularDataset(features[rows], labels[rows])


def labels_array(dataset: Dataset) -> np.ndarray:
    return np.asarray(getattr(dataset, "labels"), dtype=np.int64).reshape(-1)


def _hospital_row_indices(hospital: str) -> np.ndarray:
    if hospital not in PARTITION_HOSPITALS:
        raise ValueError(f"Unsupported hospital {hospital!r}")
    return _row_indices_by_site()[hospital]


def hospital_partition_shares(hospital: str) -> Dict[int, int]:
    _, labels = _feature_rows()
    rows = _hospital_row_indices(hospital)
    shares: Dict[int, int] = {}
    for label in range(NUM_CLASSES):
        in_class = np.count_nonzero(labels == label)
        mine = np.count_nonzero(labels[rows] == label)
        shares[label] = int(round(100 * mine / in_class))
    return shares


def make_hospital_loader(hospital: str) -> Tuple[DataLoader, Dict[int, int]]:
    features, labels = _feature_rows()
    rows = _hospital_row_indices(hospital)
    dataset = TabularDataset(features[rows], labels[rows])
    counts = {
        label: int(np.count_nonzero(labels[rows] == label))
        for label in range(NUM_CLASSES)
    }

    generator = torch.Generator()
    generator.manual_seed(SEED + int(os.getenv("ROUND_OFFSET", "0")))
    loader = DataLoader(
        dataset,
        batch_size=BATCH_SIZE,
        shuffle=True,
        num_workers=0,
        generator=generator,
    )
    return loader, counts


def make_test_loader() -> DataLoader:
    return DataLoader(
        load_test_dataset(), batch_size=256, shuffle=False, num_workers=0
    )


class Net(nn.Module):
    """Small MLP for 30 numeric features."""

    def __init__(self) -> None:
        super().__init__()
        self.layers = nn.Sequential(
            nn.Linear(NUM_FEATURES, 32),
            nn.ReLU(inplace=True),
            nn.Linear(32, 16),
            nn.ReLU(inplace=True),
            nn.Linear(16, NUM_CLASSES),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.layers(x)


def get_parameters(model: nn.Module) -> List[np.ndarray]:
    return [
        parameter.detach().cpu().numpy() for parameter in model.parameters()
    ]


def set_parameters(model: nn.Module, parameters: Sequence[np.ndarray]) -> None:
    with torch.no_grad():
        for target, source in zip(model.parameters(), parameters):
            target.copy_(
                torch.as_tensor(
                    source, dtype=target.dtype, device=target.device
                )
            )


def train_one_round(
    model: nn.Module, loader: DataLoader
) -> Tuple[float, float]:
    model.train()
    optimizer = torch.optim.Adam(model.parameters(), lr=LEARNING_RATE)
    loss_fn = nn.CrossEntropyLoss()

    total_loss = 0.0
    total_correct = 0
    total_examples = 0

    for _ in range(LOCAL_EPOCHS):
        for rows, labels in loader:
            rows = rows.to(DEVICE)
            labels = labels.reshape(-1).long().to(DEVICE)

            optimizer.zero_grad()
            logits = model(rows)
            loss = loss_fn(logits, labels)
            loss.backward()
            optimizer.step()

            batch = labels.size(0)
            total_loss += float(loss.item()) * batch
            total_correct += int((logits.argmax(dim=1) == labels).sum().item())
            total_examples += batch

    return total_loss / total_examples, total_correct / total_examples


def evaluate_full_test(
    model: nn.Module, loader: DataLoader
) -> Tuple[
    float, float, float, List[float], np.ndarray, List[Dict[str, float]]
]:
    """Same return shape as the PathMNIST workload."""

    model.eval()
    loss_fn = nn.CrossEntropyLoss(reduction="sum")

    total_loss = 0.0
    total_correct = 0
    total_examples = 0
    confusion = np.zeros((NUM_CLASSES, NUM_CLASSES), dtype=np.int64)

    with torch.no_grad():
        for rows, labels in loader:
            rows = rows.to(DEVICE)
            labels = labels.reshape(-1).long().to(DEVICE)

            logits = model(rows)
            predictions = logits.argmax(dim=1)

            total_loss += float(loss_fn(logits, labels).item())
            total_correct += int((predictions == labels).sum().item())
            total_examples += labels.size(0)
            np.add.at(
                confusion, (labels.cpu().numpy(), predictions.cpu().numpy()), 1
            )

    support = confusion.sum(axis=1)
    predicted = confusion.sum(axis=0)
    true_positive = np.diag(confusion)

    recall = np.divide(
        true_positive, support, out=np.zeros(NUM_CLASSES), where=support > 0
    )
    precision = np.divide(
        true_positive,
        predicted,
        out=np.zeros(NUM_CLASSES),
        where=predicted > 0,
    )
    f1 = np.divide(
        2.0 * precision * recall,
        precision + recall,
        out=np.zeros(NUM_CLASSES),
        where=(precision + recall) > 0,
    )

    per_class_metrics: List[Dict[str, float]] = []
    for label in range(NUM_CLASSES):
        wrong = confusion[label].copy()
        wrong[label] = 0
        top_wrong_label = int(np.argmax(wrong))
        per_class_metrics.append(
            {
                "class_id": float(label),
                "support": float(support[label]),
                "predicted": float(predicted[label]),
                "true_positive": float(true_positive[label]),
                "precision": float(precision[label]),
                "recall": float(recall[label]),
                "f1": float(f1[label]),
                "top_wrong_label": float(top_wrong_label),
                "top_wrong_count": float(wrong[top_wrong_label]),
            }
        )

    macro_recall = float(np.mean(recall[ACTIVE_CLASSES]))
    return (
        total_loss / total_examples,
        total_correct / total_examples,
        macro_recall,
        recall.tolist(),
        confusion,
        per_class_metrics,
    )

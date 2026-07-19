#!/usr/bin/env python3
"""Shared model and data code for the OpenHealth admission experiment."""

from __future__ import annotations

import os
import random
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

import numpy as np
import torch
import torch.nn as nn
import torchvision.transforms as T
from medmnist import INFO, PathMNIST
from torch.utils.data import DataLoader, Dataset, Subset

SEED = 20260702
NUM_CLASSES = 9
STORY_NON_CANCER_CLASSES = [0, 1, 3, 4, 5, 6]
STORY_CANCER_CLASSES = [7, 8]
IGNORED_CLASSES = {2}
ACTIVE_CLASSES = STORY_NON_CANCER_CLASSES + STORY_CANCER_CLASSES
CLASS_NAMES = [
    INFO["pathmnist"]["label"][str(label)]
    for label in range(NUM_CLASSES)
]
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "32"))
TEST_BATCH_SIZE = int(os.getenv("TEST_BATCH_SIZE", "256"))
LOCAL_EPOCHS = int(os.getenv("LOCAL_EPOCHS", "1"))
LEARNING_RATE = float(os.getenv("LEARNING_RATE", "0.001"))
TRAIN_FRACTION = float(os.getenv("TRAIN_FRACTION", "0.80"))
CANCER_SAMPLES_PER_AB_HOSPITAL = int(
    os.getenv("CANCER_SAMPLES_PER_AB_HOSPITAL", "100")
)
if not 0.0 < TRAIN_FRACTION <= 1.0:
    raise ValueError("TRAIN_FRACTION must be in (0, 1]")
if CANCER_SAMPLES_PER_AB_HOSPITAL < 1:
    raise ValueError("CANCER_SAMPLES_PER_AB_HOSPITAL must be positive")

HERE = Path(__file__).resolve().parent
DATA_ROOT = Path(os.getenv("MEDMNIST_ROOT", str(HERE / "data")))
DATA_ROOT.mkdir(parents=True, exist_ok=True)

DEVICE = torch.device(
    os.getenv("DEVICE", "cuda" if torch.cuda.is_available() else "cpu")
)

def seed_everything(seed: int = SEED) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def transform() -> T.Compose:
    return T.Compose(
        [
            T.ToTensor(),
            T.Normalize(mean=[0.5, 0.5, 0.5], std=[0.5, 0.5, 0.5]),
        ]
    )


def load_train_dataset() -> PathMNIST:
    return PathMNIST(
        root=str(DATA_ROOT), split="train", transform=transform(), download=True
    )


def load_test_dataset() -> PathMNIST:
    return PathMNIST(
        root=str(DATA_ROOT), split="test", transform=transform(), download=True
    )


def labels_array(dataset: Dataset) -> np.ndarray:
    return np.asarray(getattr(dataset, "labels"), dtype=np.int64).reshape(-1)


def retained_count(labels: np.ndarray, label: int) -> int:
    return max(1, int(round(int((labels == label).sum()) * TRAIN_FRACTION)))


def cancer_samples_for_c(labels: np.ndarray) -> int:
    """Return an equal per-class cancer allocation for Hospital C."""

    reserved_for_ab = 2 * CANCER_SAMPLES_PER_AB_HOSPITAL
    available = [
        retained_count(labels, label) - reserved_for_ab
        for label in STORY_CANCER_CLASSES
    ]
    if min(available) < 1:
        raise ValueError(
            "Not enough retained cancer samples for the configured A/B caps "
            "and at least one sample per cancer class at Hospital C"
        )
    return min(available)


def expected_partition_size(dataset: Dataset) -> int:
    labels = labels_array(dataset)
    non_cancer = sum(
        retained_count(labels, label) for label in STORY_NON_CANCER_CLASSES
    )
    cancer_per_class = (
        2 * CANCER_SAMPLES_PER_AB_HOSPITAL + cancer_samples_for_c(labels)
    )
    return non_cancer + len(STORY_CANCER_CLASSES) * cancer_per_class


def partition_indices(dataset: Dataset, hospital: str, seed: int = SEED) -> List[int]:
    """Create deterministic, disjoint hospital partitions by class."""

    hospital = hospital.upper()
    if hospital not in {"A", "B", "C"}:
        raise ValueError("hospital must be A, B, or C")

    labels = labels_array(dataset)
    c_cancer_count = cancer_samples_for_c(labels)
    selected: List[int] = []

    for label in ACTIVE_CLASSES:
        class_indices = np.flatnonzero(labels == label)
        rng = np.random.default_rng(seed + label)
        shuffled = rng.permutation(class_indices)

        # Apply the requested global training fraction exactly once.
        keep_count = retained_count(labels, label)
        kept = shuffled[:keep_count]

        if label in STORY_CANCER_CLASSES:
            required = 2 * CANCER_SAMPLES_PER_AB_HOSPITAL
            if keep_count <= required:
                raise ValueError(
                    f"Class {label} has {keep_count} retained samples; "
                    f"more than {required} are required for A, B, and C"
                )
            a_count = CANCER_SAMPLES_PER_AB_HOSPITAL
            b_count = CANCER_SAMPLES_PER_AB_HOSPITAL
            kept = kept[:a_count + b_count + c_cancer_count]
        else:
            # A and B own the non-cancer data and split odd remainders.
            a_count = keep_count // 2
            b_count = keep_count - a_count
        a_end = a_count
        b_end = a_count + b_count

        slices = {
            "A": kept[:a_end],
            "B": kept[a_end:b_end],
            # C receives all remaining cancer data and no non-cancer data.
            "C": kept[b_end:],
        }
        selected.extend(int(index) for index in slices[hospital])

    selected.sort()
    return selected


def hospital_counts(dataset: Dataset, indices: Sequence[int]) -> Dict[int, int]:
    labels = labels_array(dataset)
    selected = labels[np.asarray(indices, dtype=np.int64)]
    return {
        label: int(np.count_nonzero(selected == label))
        for label in range(NUM_CLASSES)
    }


def make_hospital_loader(hospital: str) -> Tuple[DataLoader, Dict[int, int]]:
    dataset = load_train_dataset()
    indices = partition_indices(dataset, hospital)
    subset = Subset(dataset, indices)
    counts = hospital_counts(dataset, indices)

    generator = torch.Generator()
    generator.manual_seed(SEED + int(os.getenv("ROUND_OFFSET", "0")))

    loader = DataLoader(
        subset,
        batch_size=BATCH_SIZE,
        shuffle=True,
        num_workers=0,
        generator=generator,
        pin_memory=(DEVICE.type == "cuda"),
    )
    return loader, counts


def make_test_loader() -> DataLoader:
    dataset = load_test_dataset()
    labels = labels_array(dataset)
    indices = np.flatnonzero(~np.isin(labels, list(IGNORED_CLASSES))).tolist()
    subset = Subset(dataset, indices)

    return DataLoader(
        subset,
        batch_size=TEST_BATCH_SIZE,
        shuffle=False,
        num_workers=0,
        pin_memory=(DEVICE.type == "cuda"),
    )


class Net(nn.Module):
    """Stronger CNN for 28x28 PathMNIST images."""

    def __init__(self) -> None:
        super().__init__()
        # Use GroupNorm instead of BatchNorm to improve stability in federated
        # settings where running statistics are not synchronized across clients.
        self.features = nn.Sequential(
            nn.Conv2d(3, 32, kernel_size=3, stride=1, padding=1),
            nn.GroupNorm(8, 32),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),

            nn.Conv2d(32, 64, kernel_size=3, stride=1, padding=1),
            nn.GroupNorm(8, 64),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),

            nn.Conv2d(64, 128, kernel_size=3, stride=1, padding=1),
            nn.GroupNorm(16, 128),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
        )

        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(128 * 3 * 3, 256),
            nn.ReLU(inplace=True),
            nn.Dropout(p=0.3),
            nn.Linear(256, NUM_CLASSES),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.features(x)
        return self.classifier(x)


def get_parameters(model: nn.Module) -> List[np.ndarray]:
    return [parameter.detach().cpu().numpy() for parameter in model.parameters()]


def set_parameters(model: nn.Module, parameters: Sequence[np.ndarray]) -> None:
    with torch.no_grad():
        for target, source in zip(model.parameters(), parameters):
            target.copy_(
                torch.as_tensor(source, dtype=target.dtype, device=target.device)
            )


def train_one_round(model: nn.Module, loader: DataLoader) -> Tuple[float, float]:
    model.train()
    optimizer = torch.optim.Adam(model.parameters(), lr=LEARNING_RATE)
    loss_fn = nn.CrossEntropyLoss()

    total_loss = 0.0
    total_correct = 0
    total_examples = 0

    for _ in range(LOCAL_EPOCHS):
        for images, labels in loader:
            images = images.to(DEVICE, non_blocking=True)
            labels = labels.reshape(-1).long().to(DEVICE, non_blocking=True)

            optimizer.zero_grad()
            logits = model(images)
            loss = loss_fn(logits, labels)
            loss.backward()
            # Clip gradients to stabilize client updates in federated averaging.
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
            optimizer.step()

            batch = labels.size(0)
            total_loss += float(loss.item()) * batch
            total_correct += int((logits.argmax(dim=1) == labels).sum().item())
            total_examples += batch

    return total_loss / total_examples, total_correct / total_examples


def evaluate_full_test(
    model: nn.Module, loader: DataLoader
) -> Tuple[
    float,
    float,
    float,
    List[float],
    np.ndarray,
    List[Dict[str, float]],
]:
    """Evaluate the global model on the complete labels 0-8 test set.

    The confusion matrix uses rows=true labels and columns=predicted labels.
    """

    model.eval()
    loss_fn = nn.CrossEntropyLoss(reduction="sum")

    total_loss = 0.0
    total_correct = 0
    total_examples = 0
    confusion = np.zeros((NUM_CLASSES, NUM_CLASSES), dtype=np.int64)

    with torch.no_grad():
        for images, labels in loader:
            images = images.to(DEVICE, non_blocking=True)
            labels = labels.reshape(-1).long().to(DEVICE, non_blocking=True)

            logits = model(images)
            predictions = logits.argmax(dim=1)

            total_loss += float(loss_fn(logits, labels).item())
            total_correct += int((predictions == labels).sum().item())
            total_examples += labels.size(0)

            labels_cpu = labels.cpu().numpy()
            predictions_cpu = predictions.cpu().numpy()
            np.add.at(confusion, (labels_cpu, predictions_cpu), 1)

    support = confusion.sum(axis=1)
    predicted = confusion.sum(axis=0)
    true_positive = np.diag(confusion)

    recall = np.divide(
        true_positive,
        support,
        out=np.zeros(NUM_CLASSES, dtype=np.float64),
        where=support > 0,
    )
    precision = np.divide(
        true_positive,
        predicted,
        out=np.zeros(NUM_CLASSES, dtype=np.float64),
        where=predicted > 0,
    )
    f1 = np.divide(
        2.0 * precision * recall,
        precision + recall,
        out=np.zeros(NUM_CLASSES, dtype=np.float64),
        where=(precision + recall) > 0,
    )

    per_class_metrics: List[Dict[str, float]] = []
    for label in range(NUM_CLASSES):
        wrong = confusion[label].copy()
        wrong[label] = 0
        top_wrong_label = int(np.argmax(wrong))
        top_wrong_count = int(wrong[top_wrong_label])

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
                "top_wrong_count": float(top_wrong_count),
            }
        )

    for label in IGNORED_CLASSES:
        if support[label] != 0:
            raise AssertionError(
                f"Ignored class {label} unexpectedly appeared in evaluation"
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

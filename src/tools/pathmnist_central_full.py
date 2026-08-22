#!/usr/bin/env python3
"""
Centralized PathMNIST control.

Purpose
-------
Train the exact OpenHealth CNN on the complete PathMNIST training split,
excluding Background (label 1), and evaluate on the complete test split
excluding Background.

This is an analytical diagnostic only. It does not use the federation,
Hub, admission machinery, or any OpenHealth runtime state.
"""

from __future__ import annotations

import argparse
import csv
import json
import random
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torchvision.transforms as T
from medmnist import INFO, PathMNIST
from torch.utils.data import DataLoader, Subset


SEED = 20260702
NUM_CLASSES = 9

BACKGROUND = 1
IGNORED_CLASSES = {BACKGROUND}

NON_CANCER_CLASSES = [0, 2, 3, 4, 5, 6]
CANCER_CLASSES = [7, 8]
ACTIVE_CLASSES = NON_CANCER_CLASSES + CANCER_CLASSES

CLASS_NAMES = [
    INFO["pathmnist"]["label"][str(label)]
    for label in range(NUM_CLASSES)
]


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def transform() -> T.Compose:
    return T.Compose(
        [
            T.ToTensor(),
            T.Normalize(
                mean=[0.5, 0.5, 0.5],
                std=[0.5, 0.5, 0.5],
            ),
        ]
    )


class Net(nn.Module):
    """Exact CNN used by the OpenHealth PathMNIST experiment."""

    def __init__(self) -> None:
        super().__init__()

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


def labels_array(dataset) -> np.ndarray:
    return np.asarray(dataset.labels, dtype=np.int64).reshape(-1)


def active_subset(dataset) -> Subset:
    labels = labels_array(dataset)
    indices = np.flatnonzero(
        ~np.isin(labels, list(IGNORED_CLASSES))
    ).tolist()
    return Subset(dataset, indices)


def make_loaders(
    data_root: Path,
    batch_size: int,
    test_batch_size: int,
    device: torch.device,
):


    data_root.mkdir(parents=True, exist_ok=True)
    train_dataset = PathMNIST(
        root=str(data_root),
        split="train",
        transform=transform(),
        download=True,
    )
    test_dataset = PathMNIST(
        root=str(data_root),
        split="test",
        transform=transform(),
        download=True,
    )

    train_subset = active_subset(train_dataset)
    test_subset = active_subset(test_dataset)

    generator = torch.Generator()
    generator.manual_seed(SEED)

    train_loader = DataLoader(
        train_subset,
        batch_size=batch_size,
        shuffle=True,
        num_workers=0,
        generator=generator,
        pin_memory=(device.type == "cuda"),
    )

    test_loader = DataLoader(
        test_subset,
        batch_size=test_batch_size,
        shuffle=False,
        num_workers=0,
        pin_memory=(device.type == "cuda"),
    )

    return (
        train_dataset,
        test_dataset,
        train_loader,
        test_loader,
    )


def train_one_round(
    model: nn.Module,
    loader: DataLoader,
    device: torch.device,
    learning_rate: float,
):
    """
    Match OpenHealth train_one_round().

    Important: Adam is recreated for every round, exactly as in the
    federated client implementation.
    """

    model.train()

    optimizer = torch.optim.Adam(
        model.parameters(),
        lr=learning_rate,
    )
    loss_fn = nn.CrossEntropyLoss()

    total_loss = 0.0
    total_correct = 0
    total_examples = 0

    for images, labels in loader:
        images = images.to(device, non_blocking=True)
        labels = labels.reshape(-1).long().to(
            device,
            non_blocking=True,
        )

        optimizer.zero_grad()

        logits = model(images)
        loss = loss_fn(logits, labels)

        loss.backward()

        torch.nn.utils.clip_grad_norm_(
            model.parameters(),
            max_norm=5.0,
        )

        optimizer.step()

        batch = labels.size(0)

        total_loss += float(loss.item()) * batch
        total_correct += int(
            (logits.argmax(dim=1) == labels).sum().item()
        )
        total_examples += batch

    return (
        total_loss / total_examples,
        total_correct / total_examples,
    )


def evaluate(
    model: nn.Module,
    loader: DataLoader,
    device: torch.device,
):
    model.eval()
    loss_fn = nn.CrossEntropyLoss(reduction="sum")

    confusion = np.zeros(
        (NUM_CLASSES, NUM_CLASSES),
        dtype=np.int64,
    )

    total_loss = 0.0
    total_examples = 0

    with torch.no_grad():
        for images, labels in loader:
            images = images.to(device, non_blocking=True)
            labels = labels.reshape(-1).long().to(
                device,
                non_blocking=True,
            )

            logits = model(images)
            total_loss += float(
                loss_fn(logits, labels).item()
            )
            total_examples += labels.size(0)

            predictions = logits.argmax(dim=1)

            true_np = labels.cpu().numpy()
            pred_np = predictions.cpu().numpy()

            np.add.at(
                confusion,
                (true_np, pred_np),
                1,
            )

    class_metrics = []

    for label in range(NUM_CLASSES):
        tp = int(confusion[label, label])
        support = int(confusion[label, :].sum())
        predicted = int(confusion[:, label].sum())

        recall = tp / support if support else 0.0
        precision = tp / predicted if predicted else 0.0

        if precision + recall:
            f1 = (
                2.0
                * precision
                * recall
                / (precision + recall)
            )
        else:
            f1 = 0.0

        wrong = confusion[label].copy()
        wrong[label] = 0

        top_wrong_label = int(np.argmax(wrong))
        top_wrong_count = int(wrong[top_wrong_label])

        class_metrics.append(
            {
                "class_id": label,
                "class_name": CLASS_NAMES[label],
                "support": support,
                "predicted": predicted,
                "true_positive": tp,
                "precision": precision,
                "recall": recall,
                "f1": f1,
                "top_wrong_label": top_wrong_label,
                "top_wrong_name": CLASS_NAMES[
                    top_wrong_label
                ],
                "top_wrong_count": top_wrong_count,
            }
        )

    correct = sum(
        int(confusion[label, label])
        for label in ACTIVE_CLASSES
    )

    active_support = sum(
        int(confusion[label].sum())
        for label in ACTIVE_CLASSES
    )

    accuracy = correct / active_support

    macro_recall = float(
        np.mean(
            [
                class_metrics[label]["recall"]
                for label in ACTIVE_CLASSES
            ]
        )
    )

    non_cancer_recall = float(
        np.mean(
            [
                class_metrics[label]["recall"]
                for label in NON_CANCER_CLASSES
            ]
        )
    )

    cancer_recall = float(
        np.mean(
            [
                class_metrics[label]["recall"]
                for label in CANCER_CLASSES
            ]
        )
    )

    cancer_f1 = float(
        np.mean(
            [
                class_metrics[label]["f1"]
                for label in CANCER_CLASSES
            ]
        )
    )

    return {
        "loss": total_loss / total_examples,
        "accuracy": accuracy,
        "macro_recall": macro_recall,
        "non_cancer_recall": non_cancer_recall,
        "cancer_recall": cancer_recall,
        "cancer_f1": cancer_f1,
        "class_7_recall": class_metrics[7]["recall"],
        "class_8_recall": class_metrics[8]["recall"],
        "confusion": confusion,
        "class_metrics": class_metrics,
    }


def save_confusion(
    path: Path,
    confusion: np.ndarray,
) -> None:
    with path.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as handle:
        writer = csv.writer(handle)

        writer.writerow(
            ["true\\predicted"]
            + [
                f"{i}:{CLASS_NAMES[i]}"
                for i in range(NUM_CLASSES)
            ]
        )

        for i, row in enumerate(confusion):
            writer.writerow(
                [
                    f"{i}:{CLASS_NAMES[i]}",
                    *[int(x) for x in row],
                ]
            )


def save_class_metrics(path: Path, rows) -> None:
    fields = [
        "class_id",
        "class_name",
        "support",
        "predicted",
        "true_positive",
        "precision",
        "recall",
        "f1",
        "top_wrong_label",
        "top_wrong_name",
        "top_wrong_count",
    ]

    with path.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=fields,
        )
        writer.writeheader()
        writer.writerows(rows)


def print_class7(result) -> None:
    row = result["confusion"][7]
    support = int(row.sum())
    correct = int(row[7])

    wrong = sorted(
        [
            (
                int(row[i]),
                i,
                CLASS_NAMES[i],
            )
            for i in range(NUM_CLASSES)
            if i != 7 and row[i] > 0
        ],
        reverse=True,
    )

    print("\nClass 7 diagnostic")
    print(f"  support = {support}")
    print(f"  correct = {correct}")
    print(
        f"  recall  = "
        f"{result['class_7_recall']:.4f}"
    )
    print("  misclassifications:")

    for count, label, name in wrong:
        print(
            f"    {label}:{name:<38} "
            f"{count:>4} "
            f"({100.0 * count / support:5.1f}%)"
        )


def main() -> None:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--data-root",
        type=Path,
        default=Path("/app/pathmnist/data"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("/tmp/pathmnist-central-full"),
    )
    parser.add_argument(
        "--rounds",
        type=int,
        default=20,
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=32,
    )
    parser.add_argument(
        "--test-batch-size",
        type=int,
        default=256,
    )
    parser.add_argument(
        "--learning-rate",
        type=float,
        default=0.001,
    )

    args = parser.parse_args()

    device = torch.device(
        "cuda"
        if torch.cuda.is_available()
        else "cpu"
    )

    seed_everything(SEED)

    args.output.mkdir(
        parents=True,
        exist_ok=True,
    )

    (
        train_dataset,
        test_dataset,
        train_loader,
        test_loader,
    ) = make_loaders(
        args.data_root,
        args.batch_size,
        args.test_batch_size,
        device,
    )

    train_labels = labels_array(train_dataset)
    test_labels = labels_array(test_dataset)

    train_counts = {
        label: int(
            np.count_nonzero(train_labels == label)
        )
        for label in range(NUM_CLASSES)
    }

    test_counts = {
        label: int(
            np.count_nonzero(test_labels == label)
        )
        for label in range(NUM_CLASSES)
    }

    print("Centralized PathMNIST control")
    print(f"device={device}")
    print(f"seed={SEED}")
    print(f"rounds={args.rounds}")
    print(f"batch_size={args.batch_size}")
    print(f"learning_rate={args.learning_rate}")
    print("excluded training/test label = 1:background")
    print(
        f"training samples={len(train_loader.dataset)}"
    )
    print(
        f"test samples={len(test_loader.dataset)}"
    )

    model = Net().to(device)

    history = []

    for round_number in range(1, args.rounds + 1):
        train_loss, train_accuracy = train_one_round(
            model,
            train_loader,
            device,
            args.learning_rate,
        )

        result = evaluate(
            model,
            test_loader,
            device,
        )

        history.append(
            {
                "round": round_number,
                "train_loss": train_loss,
                "train_accuracy": train_accuracy,
                "accuracy": result["accuracy"],
                "macro_recall": result["macro_recall"],
                "non_cancer_recall":
                    result["non_cancer_recall"],
                "cancer_recall":
                    result["cancer_recall"],
                "cancer_f1":
                    result["cancer_f1"],
                "class_7_recall":
                    result["class_7_recall"],
                "class_8_recall":
                    result["class_8_recall"],
            }
        )

        print(
            f"round={round_number:2d} "
            f"overall={result['accuracy']:.4f} "
            f"macro={result['macro_recall']:.4f} "
            f"non_cancer="
            f"{result['non_cancer_recall']:.4f} "
            f"cancer={result['cancer_recall']:.4f} "
            f"c7={result['class_7_recall']:.4f} "
            f"c8={result['class_8_recall']:.4f}"
        )

    with (
        args.output / "metrics.csv"
    ).open(
        "w",
        newline="",
        encoding="utf-8",
    ) as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=list(history[0]),
        )
        writer.writeheader()
        writer.writerows(history)

    save_confusion(
        args.output / "confusion_counts.csv",
        result["confusion"],
    )

    save_class_metrics(
        args.output / "class_metrics.csv",
        result["class_metrics"],
    )

    torch.save(
        model.state_dict(),
        args.output / "model.pt",
    )

    metadata = {
        "design": "centralized_full_pathmnist",
        "excluded_labels": [1],
        "active_labels": ACTIVE_CLASSES,
        "non_cancer_labels": NON_CANCER_CLASSES,
        "cancer_labels": CANCER_CLASSES,
        "seed": SEED,
        "rounds": args.rounds,
        "epochs_per_round": 3,
        "batch_size": args.batch_size,
        "learning_rate": args.learning_rate,
        "optimizer": "Adam reset each round",
        "gradient_clip_norm": 5.0,
        "train_class_counts": train_counts,
        "test_class_counts": test_counts,
    }

    (
        args.output / "metadata.json"
    ).write_text(
        json.dumps(metadata, indent=2),
        encoding="utf-8",
    )

    print("\nFinal central metrics")
    for key in (
        "accuracy",
        "cancer_f1",
        "cancer_recall",
        "class_7_recall",
        "class_8_recall",
        "macro_recall",
        "non_cancer_recall",
    ):
        print(f"  {key}={result[key]}")

    print_class7(result)

    print(
        f"\nArtifacts written to {args.output}"
    )


if __name__ == "__main__":
    main()

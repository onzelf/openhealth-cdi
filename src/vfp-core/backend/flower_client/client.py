# src/vfp-core/backend/flower_client/client.py
#
# PathMNIST Flower client for the OpenHealth/FLICS PoC.
#
# Hospital A contributes/evaluates PathMNIST labels 0-2.
# Hospital B contributes/evaluates PathMNIST labels 3-5.
#
# Admission governance remains outside this process. This client only performs
# local dataset selection, local training/evaluation, and Flower communication.

from __future__ import annotations

import os
import time
from typing import Dict, Iterable, List, Sequence, Tuple

import flwr as fl
import medmnist
import numpy as np
import requests
import torch
import torch.nn as nn
import torch.optim as optim
import torchvision.transforms as T
from medmnist import INFO
from torch.utils.data import DataLoader, Dataset, Subset

from pathlib import Path

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

HOSPITAL = os.getenv("HOSPITAL", "A").strip().upper()
SERVER = os.getenv("SERVER_ADDRESS", "flower-server:8080")
HUB_URL = os.getenv("HUB_URL", "http://fc-hub:8080").rstrip("/")
RUN_ID = os.getenv("RUN_ID", "local-pathmnist-ab-001")
ORG_ID = os.getenv("ORG_ID", f"org://Hospital{HOSPITAL}")
DATA_ROOT = os.getenv("MEDMNIST_ROOT", "/tmp/medmnist")
DATASET_FLAG = os.getenv("MEDMNIST_DATASET", "pathmnist").strip().lower()

BATCH_SIZE = int(os.getenv("BATCH_SIZE", "64"))
TEST_BATCH_SIZE = int(os.getenv("TEST_BATCH_SIZE", "256"))
EPOCHS = int(os.getenv("LOCAL_EPOCHS", "1"))
LEARNING_RATE = float(os.getenv("LEARNING_RATE", "0.01"))

MAX_RETRIES = int(os.getenv("MAX_RETRIES", "0"))
RETRY_INTERVAL = int(os.getenv("RETRY_INTERVAL", "10"))
HUB_REGISTER_RETRY_INTERVAL = int(
    os.getenv("HUB_REGISTER_RETRY_INTERVAL", "2")
)

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

PATHMNIST_LABELS: Dict[int, str] = {
    0: "adipose",
    1: "background",
    2: "debris",
    3: "lymphocytes",
    4: "mucus",
    5: "smooth_muscle",
    6: "normal_colon_mucosa",
    7: "cancer_associated_stroma",
    8: "colorectal_adenocarcinoma_epithelium",
}

HOSPITAL_LABELS: Dict[str, Tuple[int, ...]] = {
    "A": (0, 1, 2),
    "B": (3, 4, 5),
}


def validate_configuration() -> None:
    if DATASET_FLAG != "pathmnist":
        raise ValueError(
            f"Unsupported MEDMNIST_DATASET={DATASET_FLAG!r}; "
            "this client is configured for 'pathmnist'."
        )

    if HOSPITAL not in HOSPITAL_LABELS:
        raise ValueError(
            f"Unsupported HOSPITAL={HOSPITAL!r}; expected one of "
            f"{sorted(HOSPITAL_LABELS)}."
        )

    if BATCH_SIZE < 1 or TEST_BATCH_SIZE < 1:
        raise ValueError("Batch sizes must be positive integers.")

    if EPOCHS < 1:
        raise ValueError("LOCAL_EPOCHS must be at least 1.")

    if LEARNING_RATE <= 0:
        raise ValueError("LEARNING_RATE must be positive.")


def now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())


def log(message: str) -> None:
    print(f"[hospital-{HOSPITAL}:{now()}] {message}", flush=True)


def register_with_hub() -> None:
    partition = 0 if HOSPITAL == "A" else 1
    payload = {
        "run_id": RUN_ID,
        "org_id": ORG_ID,
        "org_label": f"Hospital {HOSPITAL}",
        "data_partition": partition,
        "metadata": {
            "hospital": HOSPITAL,
            "labels": list(HOSPITAL_LABELS[HOSPITAL]),
            "flower_server": SERVER,
        },
    }

    while True:
        try:
            response = requests.post(
                f"{HUB_URL}/clients/register",
                json=payload,
                timeout=10,
            )
            response.raise_for_status()
            log(
                f"registered with Hub: run_id={RUN_ID} "
                f"org_id={ORG_ID}"
            )
            return
        except Exception as exc:
            log(
                f"Hub registration failed: {type(exc).__name__}: {exc}; "
                f"retrying in {HUB_REGISTER_RETRY_INTERVAL} seconds"
            )
            time.sleep(HUB_REGISTER_RETRY_INTERVAL)


# ---------------------------------------------------------------------
# PathMNIST dataset
# ---------------------------------------------------------------------

def dataset_labels(dataset: Dataset) -> np.ndarray:
    """Return MedMNIST labels as a flat integer array."""
    labels = getattr(dataset, "labels", None)
    if labels is None:
        raise AttributeError("MedMNIST dataset does not expose a 'labels' array.")
    return np.asarray(labels, dtype=np.int64).reshape(-1)


def subset_for_labels(
    dataset: Dataset,
    allowed_labels: Iterable[int],
) -> Subset:
    """Select only samples whose PathMNIST label is explicitly allowed."""
    allowed = np.asarray(sorted(set(allowed_labels)), dtype=np.int64)
    labels = dataset_labels(dataset)
    indices = np.flatnonzero(np.isin(labels, allowed)).tolist()

    if not indices:
        raise RuntimeError(
            f"No samples found for PathMNIST labels {allowed.tolist()}."
        )

    return Subset(dataset, indices)


def label_counts(dataset: Dataset, allowed_labels: Sequence[int]) -> Dict[int, int]:
    """Count selected labels in a MedMNIST dataset."""
    labels = dataset_labels(dataset)
    return {
        label: int(np.count_nonzero(labels == label))
        for label in allowed_labels
    }


def load_data() -> Tuple[DataLoader, DataLoader, int, int]:
    """
    Load PathMNIST and create hospital-specific train/test partitions.

    Both hospitals use the global nine-class label space so Flower can
    aggregate identically shaped model parameters. Each hospital's local
    observations are restricted to its assigned labels.
    """
    info = INFO[DATASET_FLAG]
    data_class = getattr(medmnist, info["python_class"])
    Path(DATA_ROOT).mkdir(parents=True, exist_ok=True)

    num_classes = len(info["label"])
    num_channels = int(info["n_channels"])

    transform = T.Compose(
        [
            T.ToTensor(),
            T.Normalize(
                mean=[0.5] * num_channels,
                std=[0.5] * num_channels,
            ),
        ]
    )

    train_dataset = data_class(
        root=DATA_ROOT,
        split="train",
        transform=transform,
        download=True,
    )
    test_dataset = data_class(
        root=DATA_ROOT,
        split="test",
        transform=transform,
        download=True,
    )

    allowed_labels = HOSPITAL_LABELS[HOSPITAL]

    train_subset = subset_for_labels(train_dataset, allowed_labels)
    test_subset = subset_for_labels(test_dataset, allowed_labels)

    train_counts = label_counts(train_dataset, allowed_labels)
    test_counts = label_counts(test_dataset, allowed_labels)
    label_names = [PATHMNIST_LABELS[label] for label in allowed_labels]

    log(
        "PathMNIST partition loaded: "
        f"labels={list(allowed_labels)} "
        f"pathologies={label_names} "
        f"train_samples={len(train_subset)} "
        f"test_samples={len(test_subset)} "
        f"train_counts={train_counts} "
        f"test_counts={test_counts}"
    )

    train_loader = DataLoader(
        train_subset,
        batch_size=BATCH_SIZE,
        shuffle=True,
        num_workers=0,
    )
    test_loader = DataLoader(
        test_subset,
        batch_size=TEST_BATCH_SIZE,
        shuffle=False,
        num_workers=0,
    )

    return train_loader, test_loader, num_channels, num_classes


# ---------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------

class Net(nn.Module):
    """
    Small CNN for 28x28 PathMNIST images.

    The nine-class output is retained even though the initial A+B federation
    contributes only labels 0-5. Labels 6-8 remain available for the later
    Hospital C admission scenario.
    """

    def __init__(self, num_channels: int, num_classes: int) -> None:
        super().__init__()
        self.seq = nn.Sequential(
            nn.Conv2d(num_channels, 32, kernel_size=3, stride=1),
            nn.ReLU(),
            nn.MaxPool2d(2),
            nn.Conv2d(32, 64, kernel_size=3, stride=1),
            nn.ReLU(),
            nn.MaxPool2d(2),
            nn.Flatten(),
            nn.Linear(64 * 5 * 5, 128),
            nn.ReLU(),
            nn.Linear(128, num_classes),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.seq(x)


def get_parameters(model: nn.Module) -> List[np.ndarray]:
    return [
        parameter.detach().cpu().numpy()
        for parameter in model.parameters()
    ]


def set_parameters(
    model: nn.Module,
    parameters: Sequence[np.ndarray],
) -> None:
    model_parameters = list(model.parameters())

    if len(model_parameters) != len(parameters):
        raise ValueError(
            "Parameter-count mismatch: "
            f"model={len(model_parameters)}, received={len(parameters)}."
        )

    with torch.no_grad():
        for model_parameter, received in zip(model_parameters, parameters):
            received_tensor = torch.as_tensor(
                received,
                device=model_parameter.device,
                dtype=model_parameter.dtype,
            )

            if received_tensor.shape != model_parameter.shape:
                raise ValueError(
                    "Parameter-shape mismatch: "
                    f"expected={tuple(model_parameter.shape)}, "
                    f"received={tuple(received_tensor.shape)}."
                )

            model_parameter.copy_(received_tensor)


# ---------------------------------------------------------------------
# Local training and evaluation
# ---------------------------------------------------------------------

def train_local(
    model: nn.Module,
    loader: DataLoader,
    epochs: int,
) -> Tuple[float, float]:
    model.train()

    optimizer = optim.SGD(model.parameters(), lr=LEARNING_RATE)
    loss_fn = nn.CrossEntropyLoss()

    total_loss = 0.0
    total_correct = 0
    total_examples = 0

    for _ in range(epochs):
        for images, labels in loader:
            images = images.to(DEVICE)
            labels = labels.reshape(-1).long().to(DEVICE)

            optimizer.zero_grad()
            logits = model(images)
            loss = loss_fn(logits, labels)
            loss.backward()
            optimizer.step()

            batch_size = labels.size(0)
            total_loss += float(loss.item()) * batch_size
            total_correct += int((logits.argmax(dim=1) == labels).sum().item())
            total_examples += batch_size

    average_loss = total_loss / max(total_examples, 1)
    accuracy = total_correct / max(total_examples, 1)

    return average_loss, accuracy


def evaluate_local(
    model: nn.Module,
    loader: DataLoader,
) -> Tuple[float, float]:
    model.eval()

    loss_fn = nn.CrossEntropyLoss()
    total_loss = 0.0
    total_correct = 0
    total_examples = 0

    with torch.no_grad():
        for images, labels in loader:
            images = images.to(DEVICE)
            labels = labels.reshape(-1).long().to(DEVICE)

            logits = model(images)
            loss = loss_fn(logits, labels)

            batch_size = labels.size(0)
            total_loss += float(loss.item()) * batch_size
            total_correct += int((logits.argmax(dim=1) == labels).sum().item())
            total_examples += batch_size

    average_loss = total_loss / max(total_examples, 1)
    accuracy = total_correct / max(total_examples, 1)

    return average_loss, accuracy


# ---------------------------------------------------------------------
# Flower client
# ---------------------------------------------------------------------

class FlowerClient(fl.client.NumPyClient):
    def __init__(
        self,
        model: nn.Module,
        train_loader: DataLoader,
        test_loader: DataLoader,
    ) -> None:
        self.model = model
        self.train_loader = train_loader
        self.test_loader = test_loader

    def get_parameters(self, config):
        return get_parameters(self.model)

    def fit(self, parameters, config):
        set_parameters(self.model, parameters)

        loss, accuracy = train_local(
            self.model,
            self.train_loader,
            EPOCHS,
        )

        log(
            f"local training completed: "
            f"epochs={EPOCHS} loss={loss:.6f} accuracy={accuracy:.6f}"
        )

        return (
            get_parameters(self.model),
            len(self.train_loader.dataset),
            {
                "hospital": HOSPITAL,
                "org_id": ORG_ID,
                "train_loss": float(loss),
                "train_accuracy": float(accuracy),
            },
        )

    def evaluate(self, parameters, config):
        set_parameters(self.model, parameters)

        loss, accuracy = evaluate_local(
            self.model,
            self.test_loader,
        )

        log(
            f"local evaluation completed: "
            f"loss={loss:.6f} accuracy={accuracy:.6f}"
        )

        return (
            float(loss),
            len(self.test_loader.dataset),
            {
                "hospital": HOSPITAL,
                "org_id": ORG_ID,
                "accuracy": float(accuracy),
            },
        )


# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

def main() -> None:
    validate_configuration()

    train_loader, test_loader, num_channels, num_classes = load_data()

    model = Net(
        num_channels=num_channels,
        num_classes=num_classes,
    ).to(DEVICE)

    client = FlowerClient(
        model=model,
        train_loader=train_loader,
        test_loader=test_loader,
    )

    register_with_hub()

    log(
        f"attempting Flower connection: "
        f"server={SERVER} device={DEVICE} "
        f"channels={num_channels} classes={num_classes}"
    )

    attempt = 0
    while True:
        attempt += 1
        retry_limit = str(MAX_RETRIES) if MAX_RETRIES > 0 else "unlimited"
        try:
            log(f"connection attempt {attempt}/{retry_limit}")
            fl.client.start_numpy_client(
                server_address=SERVER,
                client=client,
            )
            log("Flower client completed")
            return
        except Exception as exc:
            if MAX_RETRIES > 0 and attempt >= MAX_RETRIES:
                log(
                    f"failed to connect after {MAX_RETRIES} attempts: "
                    f"{type(exc).__name__}: {exc}"
                )
                raise

            log(
                f"connection failed: {type(exc).__name__}: {exc}; "
                f"retrying in {RETRY_INTERVAL} seconds"
            )
            time.sleep(RETRY_INTERVAL)


if __name__ == "__main__":
    main()

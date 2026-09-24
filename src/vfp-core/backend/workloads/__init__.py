"""Training workloads the Flower client and server can run.

``workloads.active`` picks one: PathMNIST unless ``WORKLOAD`` names another.
"""

DEFAULT_WORKLOAD = "pathmnist"

# workload name -> module that implements it
WORKLOADS = {
    "pathmnist": "workloads.pathmnist_workload",
}

# Everything flower_client/client.py and flower_server/server.py import.
REQUIRED_NAMES = (
    "ACTIVE_CLASSES",
    "CANCER_SAMPLES_PER_AB_HOSPITAL",
    "CLASS_NAMES",
    "DEVICE",
    "IGNORED_CLASSES",
    "LOCAL_EPOCHS",
    "Net",
    "PATHMNIST_PARTITION_PROFILE",
    "PATHMNIST_PARTITION_SEED",
    "STORY_CANCER_CLASSES",
    "STORY_NON_CANCER_CLASSES",
    "evaluate_full_test",
    "get_parameters",
    "hospital_partition_shares",
    "labels_array",
    "load_test_dataset",
    "make_hospital_loader",
    "make_test_loader",
    "seed_everything",
    "set_parameters",
    "train_one_round",
    "transform",
)

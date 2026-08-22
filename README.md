# OpenHealth CDI

OpenHealth CDI is a proof-of-concept implementation of governed admission for
cross-organizational federated health-data collaboration.

The repository demonstrates admission-bound participation, capability-based
operations, sponsorship, evidence generation, and bounded AI-agent participation.

<p align="center">
<img src="doc/slide_0.png" width="75%">
</p>

## Quick start

### Prerequisites

- Docker
- OpenTofu
- Python 3

### Generate certificates

```bash
./src/tools/make_certs.sh

### Provision the environment
cd src/infra/tofu
tofu init

### Baseline validation
PYTHONPATH=src/vfp-core/backend python3 src/tests/test_pathmnist_metrics.py
PYTHONPATH=src/vfp-core/backend python3 src/tests/test_pathmnist_partition.py

### Mode 1B


### Publication evidence
JMIR_paper/table6/
JMIR_paper/table8/


tofu apply

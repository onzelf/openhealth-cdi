# OpenHealth-CDI Local Deployment

## 1. Purpose

This document gives the operational procedure for reproducing the OpenHealth-CDI reference implementation from a clean clone on one Linux host.

It covers the local Docker/OpenTofu deployment only. Architecture and governance semantics are documented in [ARCHITECTURE.md](ARCHITECTURE.md) and [GOVERNANCE.md](GOVERNANCE.md). Test semantics are documented in [TESTING.md](TESTING.md). AWS mapping is documented in [AWS-PORTING.md](AWS-PORTING.md).

The deployment supports two compute profiles for the PathMNIST Flower clients:

- **CPU** on a host without NVIDIA GPU hardware.
- **CUDA** on a host with NVIDIA GPU hardware and a working NVIDIA container runtime.

The governance behaviour is the same in both profiles.

A host with NVIDIA GPU hardware but a broken NVIDIA/CUDA container stack is treated as a deployment error. It must not silently fall back to CPU.

---

## 2. Deployment sequence

A clean deployment has four phases:

```text
clean clone
   |
   +-- host prerequisites and local secrets
   |
   +-- trust and identity bootstrap
   |
   +-- compute-backend selection
   |
   +-- OpenTofu deployment
   |
   +-- post-deployment member enrollment
   |
   +-- governance envelope and workload
   |
   +-- conformance regression
```

The order matters. In particular, bootstrap material must exist before `tofu apply`, and member enrollment occurs only after the issuer services are running.

---

## 3. Host prerequisites

Required on every deployment host:

- Git
- Docker
- OpenTofu
- `curl`
- `jq`
- Python 3
- OpenSSL
- standard Unix tools such as `grep`, `sed`, and `awk`

CUDA hosts additionally require:

- NVIDIA driver
- NVIDIA Container Toolkit

A CPU-only host does **not** require NVIDIA software.

Confirm the two principal runtimes:

```bash
docker info
tofu version
```

---

## 4. Repository checkout and PathMNIST data

The deployment described here corresponds to the current `main` branch.

The PathMNIST dataset is kept outside the Git repository so that it survives repository replacement and is shared by the local deployment.

From the directory that will contain the OpenHealth repository, create the data directory and download PathMNIST before cloning the repository:

```bash
mkdir -p data

curl -L \
  "https://zenodo.org/records/10519652/files/pathmnist.npz?download=1" \
  -o data/pathmnist.npz
```

Verify the downloaded file:

```bash
md5sum data/pathmnist.npz
```

Expected:

```text
a8b06965200029087d5bd730944a56c1  data/pathmnist.npz
```

Then clone the repository:

```bash
git clone https://github.com/onzelf/openhealth-cdi.git
cd openhealth-cdi
git checkout main
```

The resulting layout is:

```text
<workspace>/
├── data/
│   └── pathmnist.npz
└── openhealth-cdi/
```

`demo_start.sh` resolves the dataset by default as:

```bash
PATHMNIST_HOST="${PATHMNIST_HOST:-${REPO_ROOT}/../data/pathmnist.npz}"
```

A different location can be supplied explicitly with the `PATHMNIST_HOST` environment variable.

Before changing the deployment, confirm the current branch and working-tree state:

```bash
git status
git branch --show-current
```

The reference deployment should be reproduced from a known commit before local modifications are introduced.

---

## 5. Local verifier name resolution

`verifier.local` is the stable logical and TLS identity of the verifier edge.

For a single-host deployment, map it to host loopback:

```text
127.0.0.1 verifier.local
```

Check the current host configuration:

```bash
grep verifier.local /etc/hosts
```

If it is absent:

```bash
echo '127.0.0.1 verifier.local' | sudo tee -a /etc/hosts
```

Verify:

```bash
getent hosts verifier.local
```

Do not replace the TLS identity with an IP address and disable certificate validation.

`verifier.local` is an identity. `edge_bind_ip` is the interface on which Docker publishes the verifier and issuer ports. They are different concepts.

For multi-host AWS deployment, use private DNS or service discovery instead of the local `/etc/hosts` mapping. See [AWS-PORTING.md](AWS-PORTING.md).

---

## 6. Hal reasoning secret

Mode 1B uses a local secret file:

```text
secrets/.env
```

The file must be a regular, non-empty file containing:

```text
OPENAI_API_KEY=<key>
```

Create it from the repository root:

```bash
mkdir -p secrets
printf 'OPENAI_API_KEY=%s\n' '<key>' > secrets/.env
chmod 600 secrets/.env
```

Do not commit this file.

A common Docker bind-mount failure is an accidental directory named `secrets/.env`. Check before deployment:

```bash
test -f secrets/.env
```

Hal's OpenAI credential is unrelated to its federation holder identity.

---

## 7. Bootstrap local trust material

The repository intentionally excludes mutable trust state, private holder keys, local OpenTofu state, and secrets.

For a fresh deployment, create the demonstration mTLS material:

```bash
./src/tools/make_certs.sh
```

For the physical two-smartphone KYO demonstration, use:

```bash
./src/tools/make_certs.sh true
```

Then generate the evidence-signing key pair:

```bash
./src/tools/generate_fcac_evidence_key.sh
```

`make_certs.sh` creates a new local CA and leaf identities. Do not use it as a routine repair command on an existing governed deployment because regenerating the certificates changes those identities.

---

## 8. Select the compute backend

Run the compute selector from the repository root:

```bash
./src/tests/Test0A_verifyDockerGPU.sh
```

The expected selection is:

```text
no NVIDIA GPU hardware       -> cpu
NVIDIA GPU + healthy stack   -> cuda
NVIDIA GPU + broken stack    -> FAIL
```

The selected backend is written to:

```text
src/infra/tofu/compute.auto.tfvars
```

with one of:

```hcl
compute_backend = "cpu"
```

or:

```hcl
compute_backend = "cuda"
```

The file is local deployment state and is ignored by Git.

The Flower client image contains the CUDA-capable PyTorch build for both profiles. CPU execution is selected at runtime with `DEVICE=cpu`; CUDA execution uses `DEVICE=cuda`.

---

## 9. Run the bootstrap preflight

Run:

```bash
./src/tools/preflight_bootstrap.sh
```

The preflight validates the local deployment prerequisites before OpenTofu creates containers. It checks the trust material, evidence key pair, holder-key location, Hal secret, and `verifier.local` resolution.

It also provisions the persistent human holder identities required by the reference scenarios:

```text
Audrey   org://HospitalA
Bob      org://HospitalB
Charlie  org://HospitalA
```

A successful run ends with:

```text
BOOTSTRAP PREFLIGHT: PASS
```

Do not continue to `tofu apply` after a failed preflight.

Running this step before Docker deployment also avoids Docker creating required host directories with unsuitable ownership.

---

## 10. Initialise and validate OpenTofu

```bash
cd src/infra/tofu
tofu init
tofu validate
tofu plan
```

The generated `compute.auto.tfvars` is loaded automatically.

The local mTLS publication interface is controlled by:

```hcl
edge_bind_ip = "0.0.0.0"
```

by default. This means the Docker-published verifier and issuer ports listen on all host interfaces. It does **not** mean that clients should connect to `0.0.0.0`.

For local operation the verifier is reached through:

```text
https://verifier.local:8443
```

and the issuer tests/bootstrap use the host endpoint on port `9443`.

### 10.1 WSL2 environment
For the WSL2 reference deployment, the host-side verifier identity is mapped to loopback:

```text
127.0.0.1 verifier.local
```

Verify it with:

```bash
getent hosts verifier.local
```

The expected result includes:

```text
127.0.0.1 verifier.local
```

This host-side mapping is distinct from Docker-internal resolution. On the `fc` network, `verifier.local` is also registered as an alias of `verifier-proxy`.

`Test2B_mint_ect.sh` exercises the host-side `verifier.local` path directly and therefore provides an executable check of name resolution and TLS identity.

---

## 11. Apply the deployment

From `src/infra/tofu`:

```bash
tofu apply -auto-approve
```

The first build can take substantially longer because the Flower client image contains PyTorch and PathMNIST dependencies.

The expected principal containers are:

```text
redis
holder-signer
verifier-app
verifier-proxy
issuer-proxy
issuer-hospitala
issuer-hospitalb
fc-hub
fcac-frontend
flower-server
flower-client-a
flower-client-b
flower-client-c
hal
```

Inspect them with:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'
```

Container presence proves only that the deployment inventory is running. It does not prove governance conformance.


### Cold Start
OpenTofu builds the local application images and creates the networks, named volumes, and containers defined by 
the reference deployment. For cold starts, especially after a host or Docker Desktop/WSL restart, run from the 
repository root:

```bash
 ./src/tools/demo_start.sh 
```
The helper recreates the disposable container layer, reapplies OpenTofu, and verifies holder-key, model, and 
dashboard readiness before use.
 
---

## 12. Network topology check

The reference deployment uses two Docker networks:

- `fc` for federation-internal services.
- `agent-edge` for Hal.

The Hub joins both and is the controlled application path between Hal and the federation.

Inspect:

```bash
docker network inspect fc
docker network inspect agent-edge
```

Hal must not acquire ordinary membership of `fc`.

The executable authority for the Mode 1B isolation claim remains `Test5A_agent_isolation.sh`.

---

## 13. Post-deployment member enrollment

The holder private keys exist before deployment, but the organisation issuers do not. Enrollment therefore occurs after `tofu apply`.

Return to the repository root:

```bash
cd ~/openhealth-cdi
```

For a single-host deployment:

```bash
./src/tools/bootstrap_members.sh 127.0.0.1
```

The bootstrap enrolls or verifies the canonical issuer registrations for Audrey, Bob, and Charlie. It fails rather than silently replacing a conflicting public key or JKT.

A successful run ends with:

```text
MEMBER BOOTSTRAP: PASS
```

This is deployment bootstrap, not a conformance test. The conformance tests must not create missing participant identities as a side effect.

---

## 14. Verify the selected Flower runtime

Inspect Hospital A and B:

```bash
docker logs flower-client-a 2>&1 | grep -m1 -E 'CPU ready|CUDA ready'
docker logs flower-client-b 2>&1 | grep -m1 -E 'CPU ready|CUDA ready'
```

A CPU deployment should report `CPU ready`. A CUDA deployment should report `CUDA ready`.

`Test1C_verifyABRounds.sh` validates the backend selected in `compute.auto.tfvars` rather than assuming CUDA.

On a CUDA host, `Test0A_verifyDockerGPU.sh` may be run again after the Flower image has been built to validate the image-level CUDA path.

---

## 15. Local endpoints

| Service | Local endpoint |
| --- | --- |
| Dashboard | `http://127.0.0.1:8082` |
| Hub debug/test endpoint | `http://127.0.0.1:8080` |
| Verifier mTLS edge | `https://verifier.local:8443` |
| Issuer mTLS edge | host port `9443` |

The Flower control plane is not published as a normal host-facing service.

Open the dashboard at:

```text
http://127.0.0.1:8082
```

See [DASHBOARD.md](DASHBOARD.md) for the interface walkthrough.

---

## 16. Create or select a governance envelope

The collaboration requires an active governance envelope before envelope-bound capabilities and governed operations can be exercised.

### Physical KYO demonstration

If the administrator PKCS#12 bundles were generated, each administrator opens:

```text
https://verifier.local:8443/verify-start
```

from the corresponding authenticated device. Hospital A and Hospital B provide independent approval.

### Script-assisted local operation

The helper:

```bash
cd src/tools
./simulatePhone.sh
```

obtains the two demonstration verification codes.

The complete envelope workflow is then exercised from `src/tests` with:

```bash
./Test1A_createEnvelope.sh
```

Record the resulting envelope identifier:

```bash
export EID=<active-envelope-id>
```

Creating a new envelope is a governance action. It is not a generic deployment reset.

---

## 17. Run the A+B workload

The A+B baseline uses Hospitals A and B as the required Flower participants.

From `src/tests`:

```bash
./Test1B_postEnvelope.sh "$EID"
```

After the run completes:

```bash
./Test1C_verifyABRounds.sh
```

A completed run stores model and analytical artefacts beneath the mounted vault, including:

```text
model.pt
metrics.csv
participants.json
confusion_counts.csv
confusion_normalized.csv
class_metrics.csv
final_model_metadata.json
```

The model-run lifecycle and governance-envelope lifecycle remain distinct. A later envelope may govern use of an existing model without implying that the model was trained under that envelope.

---

## 18. Delivery regression

The top-level Mode 1B delivery regression is:

```bash
cd ~/openhealth-cdi

./src/tests/Test0C_delivery_regression.sh \
  "$EID" \
  127.0.0.1
```

A successful run ends with:

```text
DELIVERY REGRESSION GREEN

ALL DELIVERY GATES GREEN
```

The regression covers the delivery preflight, Hal isolation, Hal credential admission, Table 7 decision-plane conformance, and Mode 1B governance composition.

The complete test catalogue and the invariant established by each test are documented in [TESTING.md](TESTING.md).

---

## 19. Rebuilding a changed component

A source change is not guaranteed to alter an already-built local Docker image. When a component has changed, explicitly replace its image and container through OpenTofu.

For example, after a Flower client change:

```bash
cd src/infra/tofu

tofu apply -auto-approve \
  -replace=docker_image.flower_client \
  -replace=docker_container.flower_client_a \
  -replace=docker_container.flower_client_b \
  -replace=docker_container.flower_client_c
```

Rebuild only the component that changed.

After replacing an upstream service behind a long-lived nginx proxy, the proxy may also need recreation because nginx can retain the previously resolved Docker address. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 20. Restart versus rebuild

Use:

```bash
docker restart <container-name>
```

only when no image or infrastructure definition changed.

Use OpenTofu replacement when source, image content, mounts, environment, network membership, or other declared infrastructure changed.

Do not destroy persistent state as a generic troubleshooting technique.

In particular, the `hal-identity` Docker volume contains Hal's persistent holder identity. Removing it creates a different JKT and invalidates assumptions about existing issuer registration.

---

## 21. Teardown

From `src/infra/tofu`:

```bash
tofu destroy -auto-approve
```

A full destroy is not an ordinary reset. Issuer registries, Hal identity, governance state, and model/evidence artefacts can participate in the research record.

Determine what must be retained before deleting volumes or host-mounted state.

---

## 22. What is local implementation detail

The following mechanisms are part of the single-host reference deployment, not universal architecture requirements:

- Docker bridge networks.
- host loopback publication.
- `/etc/hosts` resolution of `verifier.local`.
- host-mounted cryptographic material.
- local filesystem model storage.
- local Redis.
- nginx Docker-name resolution behaviour.

An AWS deployment may replace these mechanisms, but it must preserve the same architectural invariants and authority relationships.

See [AWS-PORTING.md](AWS-PORTING.md).

---

## 23. Operational troubleshooting

When deployment fails, inspect the failing layer before replacing components.

Useful commands include:

```bash
docker logs --tail 200 fc-hub
docker logs --tail 200 verifier-app
docker logs --tail 200 verifier-proxy
docker logs --tail 200 issuer-hospitala
docker logs --tail 200 issuer-hospitalb
docker logs --tail 200 issuer-proxy
docker logs --tail 200 flower-server
docker logs --tail 200 flower-client-a
docker logs --tail 200 flower-client-b
docker logs --tail 200 flower-client-c
docker logs --tail 200 hal
docker logs --tail 200 fcac-frontend
```

Environment-specific failures observed during portability work, including Docker DNS and WSL host-port forwarding, are documented in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 24. Cold startup and restart of the reference deployment

The normal cold-start procedure is:

```bash
./src/tools/demo_start.sh 
```

`demo_start.sh` performs the deployment preflight before modifying the running container layer. It checks the Docker runtime, `verifier.local`, OpenTofu ownership, required networks and persistent volumes, holder identities, issuer registrations, persisted model state, and the external PathMNIST dataset.

If any prerequisite or persistence invariant is inconsistent, the script stops before removing containers.

When the preflight succeeds, the script recreates the disposable container layer through OpenTofu, preserves the validated persistent state, copies:

```text
../data/pathmnist.npz
```

into:

```text
flower-server:/tmp/medmnist/pathmnist.npz
```

and performs its runtime checks.

A successful `demo_start.sh` run should be followed by independent verification of the principal paths.

First verify the host-side verifier path, active envelope, TLS identity, and ECT minting:

```bash
cd src/tests
./Test2B_mint_ect.sh "$EID"
```

Then inspect the live governance boundary:

```bash
curl -s http://127.0.0.1:8080/administration/boundary | jq '
{
  selected_envelope_id,
  holders: [.holders[] | {principal, enrollment, can_mint}]
}'
```

Audrey and Bob should report:

```text
enrollment = enrolled
can_mint = true
```

Verify the organisation issuer registries:

```bash
docker exec issuer-hospitala \
  python -c 'import requests,json; print(json.dumps(requests.get("http://127.0.0.1:8080/members").json(),indent=2))'

docker exec issuer-hospitalb \
  python -c 'import requests,json; print(json.dumps(requests.get("http://127.0.0.1:8080/members").json(),indent=2))'
```

Finally verify the PathMNIST dataset and persisted model:

```bash
docker exec flower-server test -s /tmp/medmnist/pathmnist.npz \
  && echo "PathMNIST OK"

docker exec flower-server \
  sh -c 'find /vault/runs -name model.pt -type f -print -quit | grep -q .' \
  && echo "Model OK"
```

These checks independently establish that the cold-start procedure has restored the principal runtime and governance state rather than merely started the expected containers.

To restart one known healthy service without rebuilding or reconciling the deployment:

```bash
docker restart <container-name>
```

Use a service-specific restart only when no image, infrastructure definition, identity, or persistent-state relationship has changed.

---

## 25. Deployment completion criterion

A deployment is not complete because all containers are running.

For the portable reference deployment, completion means:

1. bootstrap preflight passes;
2. OpenTofu applies cleanly with the selected CPU or CUDA backend;
3. member bootstrap passes;
4. the A+B workload completes and `Test1C_verifyABRounds.sh` passes;
5. `Test0C_delivery_regression.sh` terminates with `ALL DELIVERY GATES GREEN`.

Those checks establish that the deployment is operational and that the delivered governance invariants remain executable on the selected compute profile.

# L1-A: the Flower execution plane on ECS

Roadmap §4. The Flower server and clients A, B and C run on Amazon ECS. The governance
plane stays on the L0 EC2 host, unchanged: UI, hub, Verifier/Gatekeeper, issuers,
Redis and Hal. L0 (tag `L0-green-2026-09`) is not modified and remains the oracle.

```
EC2 host (L0, unchanged)                        ECS cluster openhealth-l1a
  UI  Hub  Gatekeeper  Issuers  Redis  Hal         Flower server
        |  ^                                         Flower client A
        |  | 8080  (server, clients -> hub)          Flower client B
        |  +--------------------------------------   Flower client C
        +-- 8081 (hub -> Flower control) ------->
        /vault  <====== shared EFS volume ======>  /vault (server)
```

## What changes

**Application code: nothing.** Same images, same Python. Only deployment bindings
(service addresses) move to VPC configuration, which §4 allows:

| setting | L0 | L1-A |
|---|---|---|
| `HUB_URL` (server, clients) | `http://fc-hub:8080` | `http://fc-hub.openhealth.internal:8080` |
| `SERVER_ADDRESS` (clients) | `flower-server:8080` | `flower-server.openhealth.internal:8080` |
| `BACKEND_URL` (server) | `http://flower-server:8081` | `http://flower-server.openhealth.internal:8081` |
| `FLOWER_BACKEND_URL` (hub) | `http://flower-server:8081` | `http://flower-server.openhealth.internal:8081` |

Every other environment value is copied from `infra/tofu/main.tf`, except `REDIS_URL`, which the Flower server never read.

**In `infra/tofu/main.tf`** (+48/−5, second commit of this PR):

- A new variable, `flower_placement`, which is `docker` (the default, L0) or `ecs`. With `ecs`, the four Flower containers are left out.
- The hub's port is published on the host interface only when Flower is on ECS. The security group decides who may reach it.
- The hub's `FLOWER_BACKEND_URL` becomes a variable, defaulting to L0's value.
- `moved` blocks keep the Flower containers' state addresses. With the defaults, `tofu plan` on an existing host plans exactly what it planned before the change. That is the first check.

**AWS (this module, 33 resources):**

- **ECS cluster** `openhealth-l1a`: one service for the server and one per client. The clients are separate services so that each can move to its own account in L1-B. CPU on Fargate for now; GPU needs EC2 capacity (see "Not in this step").
- **Private DNS zone** `openhealth.internal` (Cloud Map): `flower-server` registered by ECS, and `fc-hub` pointing at the host's private IP. Both sides use the VPC resolver.
- **Security groups**, one rule per relation:
  - clients → server on 8080, inside the Flower group;
  - Flower → hub on 8080, through a small extra group attached to the host. The host's own SSH-only group is untouched;
  - hub → Flower control on 8081.

  Flower has **no route** to the Gatekeeper, the issuers, Redis or Hal, so Flower stays execution-only.
- **Shared `/vault` on encrypted EFS**: mounted by the Flower server task, and on the host at the same path the hub already binds (`host/mount-vault.sh`), so the hub reads the same run artefacts as in L0.

## Acceptance (roadmap §4)

| criterion | how it is checked |
|---|---|
| No change to admission, envelope, issuer or Gatekeeper semantics | no governance file is touched; `tofu plan` with the defaults plans the same as before |
| Flower server and clients use private AWS networking, same protocol | gRPC on 8080 and HTTP on 8081 over VPC addresses; same images |
| Baseline, Mode 1A and Mode 1B regressions GREEN | Test1–Test5 suite on the host (see the note below) |
| Python changes limited to configuration | none |
| L0 remains the oracle | the tag is unchanged; `flower_placement=docker` *is* L0 |

**The regression tests and the missing container.** Eight tests assume a `flower-server`
container on the host (Test0B, 1B, 1C, 1D, 1E, 3A, 4A, 4B): they `docker exec` into it to read
`/vault` and call `http://flower-server:8081`. The third commit of this PR gives them two
variables whose defaults are today's values, so L0 runs unchanged:

| variable | L0 default | L1-A |
|---|---|---|
| `FLOWER_URL` | `http://flower-server:8081` | `http://flower-server.openhealth.internal:8081` |
| `FLOWER_EXEC` | `docker exec -i flower-server` | `docker run --rm -i -v <vault-dir>:/vault -e FLOWER_URL fcac/flower-server:local` |

In L1-A the reads run the same Flower image on the host against the shared `/vault`, so the tests
see the files the ECS server wrote. Checks that only make sense for a local container (is it
running, what did its log say) are skipped with a note when Flower is remote. Test5A is untouched:
it asserts Hal cannot reach `flower-server`, which stays true.

## Run order

Mac, in this directory (`terraform.tfvars` holds the sandbox IDs and is git-ignored):

```
terraform apply
```

Host, on the L1 branch:

```
tofu plan                                                             # with defaults: same plan as before the change
tofu apply -var flower_placement=ecs -var flower_backend_url=http://flower-server.openhealth.internal:8081
./mount-vault.sh <vault_efs_id from terraform output>                  # moves /vault to EFS, restarts hub, issuers, frontend
```

Mac: `terraform apply -var desired_count=1` starts the four tasks; they register with the hub
on start. The hub loses its selected envelope on any restart (as on L0), so run the KYO ceremony
(`simulatePhone.sh`, `Test1A`) or re-select the envelope, then the regression with the two
variables set:

```
export FLOWER_URL=http://flower-server.openhealth.internal:8081
export FLOWER_EXEC="docker run --rm -i -v $HOME/openhealth-cdi/src/vfp-governance/verifier/vault:/vault -e FLOWER_URL fcac/flower-server:local"
./Test0B_delivery_preflight.sh <eid> 127.0.0.1
./Test1B_postEnvelope.sh <eid> local-pathmnist-ab-001 1800
./Test1C_verifyABRounds.sh <model run id> 10
./Test0C_delivery_regression.sh <eid> 127.0.0.1
```

## Result, 8 October 2026

Run in the sandbox with the L0 v2 host as the governance host (aws-L1 `dfc5b35`, host on
m6i.2xlarge for the day, Flower on Fargate CPU, images as built on 26 September):

- `tofu plan` with the patch and the defaults planned the same three creates as without it;
  only the `[0]` indexes and `moved` notes differ.
- Hub backend list: `flower-local` at `http://flower-server.openhealth.internal:8081`;
  `backend.available = true` (hub to Flower control port).
- From inside the tasks (ECS Exec, application-level): client and server reach the hub
  (HTTP 200) and the Flower port; verifier 8443, issuer 9443, Redis 6379, Hal 8088 and SSH on
  the host all time out. The server has the shared `/vault` mounted.
- KYO ceremony (Test1A) created envelope `4d615116...`; **Test0B GREEN**; **Test1B PASS**
  (10 rounds on ECS, model run `local-pathmnist-ab-002`, manifest bound to the envelope);
  **Test1C PASS** (accuracy 0.806, macro recall 0.751); **Test0C: ALL DELIVERY GATES GREEN**
  (0B, 5A, 5C, 5D, 5E with the four Mode 1B cases). Test1E gets its prediction from the ECS
  server but its final check expects run `-001`, hard-coded; today's model is `-002`, as it
  would be on L0 after any second run.
- One thing learned: replacing the hub container gives it a new address on the `fc` network and
  the frontend's nginx keeps the old one, so the frontend must restart too (now in `mount-vault.sh`).

**Rollback:** `tofu apply` with the defaults (Flower back on the host) and
`terraform apply -var desired_count=0` (ECS parked).

## Not in this step

- **GPU.** Fargate has none. GPU clients need an ECS capacity provider with G-instance hosts; the quota is now 24 vCPU. The images already support `DEVICE=cuda`.
- **Accounts per hospital** (L1-B), **the hub on ECS** (L1-C), **Bedrock**, and **any hub change**.
- **The NFS mount on the host is not TLS-encrypted** (`nfs-common`, not `amazon-efs-utils`). The ECS side is. A question for the SAs.

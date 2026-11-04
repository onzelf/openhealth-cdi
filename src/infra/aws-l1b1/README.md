# L1-B1: the Flower server and the clients in their own accounts

Roadmap v3 §6.1 to §6.4. The Flower server moves to its own account and clients A, B and C
move to one account each. The governance plane stays on the L0 EC2 host in the governance
account, and `/vault` stays on L1-A's EFS there (the B1 transitional relation). L1-A
(`../aws-l1a-flower-ecs`) stays applied and parked; L0 is not modified.

| Role | Account (CDI sandbox) | VPC range | Root |
|---|---|---|---|
| Governance: host, hub, verifier, issuers, Redis, Hal, `/vault` | Sandbox-18 | 172.31.0.0/16 (default VPC) | `central-18` |
| Flower server | Sandbox-43 | 10.20.0.0/16 | `flower-43` |
| Hospital A client | Sandbox-12 | 10.31.0.0/16 | `participant`, workspace `a` |
| Hospital B client | Sandbox-33 | 10.32.0.0/16 | `participant`, workspace `b` |
| Hospital C client | Sandbox-8 | 10.33.0.0/16 | `participant`, workspace `c` |

Each new account has one ECS subnet, x.x.10.0/24, in zone `euw2-az2` (the zone of the
governance host and of its EFS mount target). The ranges are part of the design: every
rule below is written against them.

```
governance 172.31.0.0/16                      Flower 10.20.0.0/16
  L0 host: hub, verifier, issuers,              flower-server (ECS, 10.20.10.0/24)
  Redis, Hal, UI                                flower-server.flower.openhealth.internal
  fc-hub.openhealth.internal
  /vault EFS (L1-A)
        |  \___________ 18<->43 ____________/  |
        |                                      |
     18<->12/33/8                          43<->12/33/8
        |                                      |
  hospital A 10.31.0.0/16     hospital B 10.32.0.0/16     hospital C 10.33.0.0/16
  (no peering between hospitals)
```

Relations (roadmap §6.2), one security-group rule each, always on the receiving side:

- clients -> Flower server TCP/8080 (rule in the Flower account, one per client subnet)
- clients -> hub TCP/8080, for registration and status; the rule opens the whole port (rule in
  governance, one per client subnet)
- hub -> Flower server TCP/8081, control (rule in the Flower account, from the host's /32 only)
- Flower server -> hub TCP/8080 (rule in governance, from 10.20.10.0/24)
- Flower server -> central EFS TCP/2049, B1 transitional only (rule on L1-A's EFS group)

Nothing reaches the verifier, the issuers, Redis or Hal: the host's other groups only admit
SSH from fixed addresses and L1-A's own Flower group.

## What each root creates

Each root has its own state and is applied with one account's credentials only (roadmap
§6.4: no role in one account administers another). That gives five states: `central-18`,
`flower-43`, and the `participant` workspaces `a`, `b` and `c`. Values one account needs from
another are handed over as variables between applies.

**`central-18`** (governance). What governance must allow, without changing anything else:

- a security group `openhealth-l1b-governance-link` on the host's network interface, with
  TCP/8080 from the Flower subnet and from each client subnet;
- one rule on L1-A's EFS group (`openhealth-l1a-vault`): TCP/2049 from 10.20.10.0/24;
- ECR repository policies: `fcac/flower-server` readable by the Flower account,
  `openhealth/flower-client` readable by the three hospital accounts;
- its side of the peerings: it accepts the four requests (stage 3) and adds a route for each;
- names: it grants the four member VPCs access to `openhealth.internal` (stage 2) and joins
  the Flower account's `flower.openhealth.internal` (stage 3).

The host, its EFS, the `openhealth.internal` zone and the ECR repositories are looked up, not
managed here.

**`flower-43`** (Flower). A VPC with one ECS subnet, an internet gateway, the ECS cluster
`openhealth-l1b`, the server's security group, the Cloud Map namespace
`flower.openhealth.internal`, and the server's task definition and service. With the three
`vault_*` variables set, a private zone named after the EFS (see "Names across accounts").
Issue #7: the secret `openhealth-l1b-flower-control-token`, which the server reads as
`FLOWER_CONTROL_TOKEN` (`control_token.tf`). Its side of the peerings: it requests 43<->18
(stage 2), accepts the three hospitals (stage 3), grants its zone to the other four VPCs
(stage 2) and joins `openhealth.internal` (stage 3).

**`participant`** (one workspace per hospital). The same base, the client's security group
(outbound only, no ingress rule), and the client's task definition and service. Issue #7: the
secret `openhealth-l1b-flower-execution-key-<a|b|c>`, which the client reads as
`EXECUTION_KEY_HEX` (`execution_key.tf`). Its side: it requests its two peerings (stage 2),
then adds its two routes and joins both zones (stage 4). A precondition stops the plan if the
workspace and the var file do not match.

**`modules/base`**: VPC, subnet, internet gateway, ECS cluster, log group, the two task roles.
**`modules/peer-links`**: one account's side of its peerings and shared zones. An accepted
request is found by the requesting account, its range and this VPC, so only the expected
request is accepted.

`desired_count` defaults to 0 in `flower-43` and `participant`: an apply builds everything
without starting a task.

### Names across accounts

Cloud Map only registers into a namespace of its own account, so there are two private zones:

- `openhealth.internal` in governance (L1-A's, unchanged), which holds `fc-hub`. Governance
  grants it to the four member VPCs, and each joins it from its own side.
- `flower.openhealth.internal` in the Flower account, which holds `flower-server`. The Flower
  account grants it to the other four VPCs, and each joins it from its own side.

A VPC cannot be associated with two private zones of the same name, which is why the Flower
zone is not also called `openhealth.internal`.

`/vault`: the EFS name `<fs-id>.efs.eu-west-2.amazonaws.com` only resolves in the file
system's own VPC, so `flower-43` creates a private zone with that name pointing at the mount
target in `euw2-az2`. The name stays the same, so the TLS check of the EFS mount helper still
matches.

The values that change from L1-A:

| setting | L1-A | L1-B1 |
|---|---|---|
| hub `FLOWER_BACKEND_URL` | `http://flower-server.openhealth.internal:8081` | `http://flower-server.flower.openhealth.internal:8081` |
| server `BACKEND_URL` | the same as the hub's | the same as the hub's |
| clients `SERVER_ADDRESS` | `flower-server.openhealth.internal:8080` | `flower-server.flower.openhealth.internal:8080` |
| `HUB_URL` (server, clients) | `http://fc-hub.openhealth.internal:8080` | unchanged |
| tests `FLOWER_URL` | `http://flower-server.openhealth.internal:8081` | `http://flower-server.flower.openhealth.internal:8081` |

## What is not in Git

Account IDs, CLI profile names, VPC, zone and EFS IDs, the host's IP, the secrets' values and
every state file stay out of the repository (`.gitignore`). Each root has a
`terraform.tfvars.example`; the participant root also has `hospital-a.tfvars.example`,
`hospital-b.tfvars.example` and `hospital-c.tfvars.example`. Copy each to the same name without
`.example` and fill in the `<...>` placeholders. The state is local, one per root (and one per
workspace in `participant`, under `terraform.tfstate.d/`); keep it outside Git.

## Prerequisites

- Terraform >= 1.6 (the AWS provider is pinned to `~> 6.0`, as in L1-A), the AWS CLI with the
  Session Manager plugin (for `aws ecs execute-command`), and `jq` and `ssh` for Test1F.
- One CLI profile per account. In what follows: `<gov-profile>`, `<flower-profile>`,
  `<a-profile>`, `<b-profile>`, `<c-profile>`; region `eu-west-2`.
- L1-A applied (`../aws-l1a-flower-ecs`): its EFS `openhealth-l1a-vault` and that EFS's group,
  and the `openhealth.internal` zone with `fc-hub`. Its four Flower services must stay at 0, or
  a second server registers with the hub. Do not destroy L1-A while L1-B1 exists.
- The images in the governance account's ECR, tag `local`: `fcac/flower-server` and
  `openhealth/flower-client`, built from the #7 branch.
- Service quotas: AWS Fargate, 'Fargate On-Demand vCPU resource count', at least 1 vCPU in the
  Flower account (2 to run a probe beside the server) and 2 vCPU in each hospital account (4 in
  Hospital A for Test1F, whose rogue runs beside A's client).
- The ECS service-linked role in each of the four new accounts (step 0).
- The issue #7 keys: `src/tools/preflight_bootstrap.sh` on the host creates the three execution
  keys and the control token in `src/vfp-governance/verifier/execution_keys/` (git-ignored), and
  `bootstrap_members.sh` registers the public halves with the issuers.

## Handovers between accounts

| Value | From (output) | Into |
|---|---|---|
| governance account, VPC, zone | `central-18`: `handover` | `flower-43` and `participant` `terraform.tfvars`: `governance` |
| the host's private IP | `central-18`: `governance_host_ip` | `flower-43` `terraform.tfvars`: `hub_cidr` (as a /32) |
| Flower account, VPC, zone | `flower-43`: `handover` | `participant` `terraform.tfvars`: `flower`; `central-18`: `flower_zone_id`, `member_vpc_ids.flower` |
| each hospital's VPC | `participant` (each workspace): `handover` | `central-18`: `member_vpc_ids`; `flower-43`: `participant_vpc_ids` |
| `/vault` IDs | `central-18`: `flower_43_vault` | `flower-43` `terraform.tfvars`: `vault_*` |

Peering IDs are never handed over: the accepting side finds the request by account, range and
VPC.

## Apply order

Peerings and zone associations need the other side to exist, so the five states are applied
in four stages. Each `plan` writes `tfplan`; read it before the `apply`. Every plan below must
show 0 to destroy, except a replaced task definition (a new image, environment or volume, as in
step 7); stop on any other destroy.

### Step 0: before starting

```
export AWS_DEFAULT_REGION=eu-west-2 AWS_PAGER=""
for p in <gov-profile> <flower-profile> <a-profile> <b-profile> <c-profile>; do aws sts get-caller-identity --profile $p --query Account --output text; done
aws ecs describe-services --profile <gov-profile> --cluster openhealth-l1a --services flower-server flower-client-a flower-client-b flower-client-c --query 'services[].[serviceName,desiredCount]' --output text
for p in <flower-profile> <a-profile> <b-profile> <c-profile>; do aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com --profile $p; done
```

All five sessions must be valid and L1-A's four services must show 0. The service-linked role
call fails harmlessly if the role already exists.

### Stage 1: each account's own base, no links yet

**1a. central-18:**

```
cd src/infra/aws-l1b1/central-18
cp terraform.tfvars.example terraform.tfvars      # profile and the four account IDs
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output handover
terraform output governance_host_ip
terraform output flower_43_vault
```

**1b. flower-43:**

```
cd src/infra/aws-l1b1/flower-43
cp terraform.tfvars.example terraform.tfvars      # profile, flower_server_image, hub_cidr, participant_account_ids
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output handover
terraform output control_token_secret
```

Leave the stage 2 and 3 lines commented.

**1c. the three hospitals:**

```
cd src/infra/aws-l1b1/participant
cp terraform.tfvars.example terraform.tfvars      # flower_client_image
cp hospital-a.tfvars.example hospital-a.tfvars    # profile; likewise b and c
terraform init
terraform workspace select -or-create a
terraform plan -var-file=hospital-a.tfvars -out=tfplan
terraform apply tfplan
terraform output handover
terraform output execution_key_secret
```

Then the same from `workspace select` with `b`/`hospital-b.tfvars` and `c`/`hospital-c.tfvars`.

### Stage 2: requests and grants

Put the handover values into the variable files:

- `central-18/terraform.tfvars`: `member_vpc_ids` (flower, A, B, C).
- `flower-43/terraform.tfvars`: `governance` and `participant_vpc_ids`.
- `participant/terraform.tfvars`: `governance` and `flower`.

Then apply each, in this order (each line plans and applies in one go; run its `plan` on its own
first to read it):

```
cd src/infra/aws-l1b1/central-18 && terraform plan -out=tfplan && terraform apply tfplan
cd ../flower-43 && terraform plan -out=tfplan && terraform apply tfplan
cd ../participant && terraform workspace select a && terraform plan -var-file=hospital-a.tfvars -out=tfplan && terraform apply tfplan
```

(and `b`, `c`). Expected: central-18 adds 4 grants; flower-43 adds 1 request and 4 grants;
each hospital adds 2 requests. Check from governance (the accepting account's list can lag a
minute behind new requests):

```
aws ec2 describe-vpc-peering-connections --profile <gov-profile> --query 'VpcPeeringConnections[].[Status.Code,RequesterVpcInfo.CidrBlock,AccepterVpcInfo.VpcId]' --output text
```

Four lines `pending-acceptance`, from 10.20, 10.31, 10.32 and 10.33.

### Stage 3: governance and Flower accept

`central-18/terraform.tfvars`: uncomment `accept_peerings = true` and set `flower_zone_id`
(from flower-43's handover). Plan and apply. Expected: 4 acceptances, 4 routes, 1 zone link.

`flower-43/terraform.tfvars`: uncomment `governance_peering_active = true` and
`accept_peerings = true`. Plan and apply. Expected: 1 route to 172.31, 3 acceptances, 3 routes,
1 zone link.

### Stage 4: the hospitals add their routes and names

`participant/terraform.tfvars`: uncomment `peerings_active = true`. Plan and apply each
workspace. Expected per hospital: 2 routes, 2 zone links.

### Step 5: the governance host

Start the host as for L1-A (the next step reads the secrets from it). On the host, on the L1 branch:

```
cd ~/openhealth-cdi/src/infra/tofu
tofu plan -var flower_placement=ecs -var flower_backend_url=http://flower-server.flower.openhealth.internal:8081
tofu apply -var flower_placement=ecs -var flower_backend_url=http://flower-server.flower.openhealth.internal:8081
docker restart fcac-frontend
df -h ~/openhealth-cdi/src/vfp-governance/verifier/vault
getent hosts flower-server.flower.openhealth.internal
```

The vault must still show the EFS. The frontend restarts because its nginx keeps the hub's old
address. `getent` gives nothing until the server runs, but must not hang.

### Step 6: the secrets (issue #7)

Each value goes in with the AWS CLI, so it never appears in Terraform state. The values are
read from the host over SSH, straight into the call, so no copy is written on the machine that
runs it. The task cannot start until its secret has a value.

```
K=openhealth-cdi/src/vfp-governance/verifier/execution_keys
aws secretsmanager put-secret-value --profile <flower-profile> --secret-id openhealth-l1b-flower-control-token --secret-string "$(ssh ubuntu@<host> cat $K/flower-control.token)" --query Name --output text
aws secretsmanager put-secret-value --profile <a-profile> --secret-id openhealth-l1b-flower-execution-key-a --secret-string "$(ssh ubuntu@<host> cat $K/flower-execution-HospitalA.privhex)" --query Name --output text
aws secretsmanager put-secret-value --profile <b-profile> --secret-id openhealth-l1b-flower-execution-key-b --secret-string "$(ssh ubuntu@<host> cat $K/flower-execution-HospitalB.privhex)" --query Name --output text
aws secretsmanager put-secret-value --profile <c-profile> --secret-id openhealth-l1b-flower-execution-key-c --secret-string "$(ssh ubuntu@<host> cat $K/flower-execution-guest-HospitalC.privhex)" --query Name --output text
```

Hospital C holds the guest key registered by its sponsor, Hospital A.

### Step 7: check the network, then add /vault

```
aws ec2 describe-vpc-peering-connections --profile <gov-profile> --query 'VpcPeeringConnections[].[Status.Code,RequesterVpcInfo.CidrBlock,AccepterVpcInfo.CidrBlock]' --output text
aws ec2 describe-vpc-peering-connections --profile <flower-profile> --query 'VpcPeeringConnections[].[Status.Code,RequesterVpcInfo.CidrBlock,AccepterVpcInfo.CidrBlock]' --output text
for p in <gov-profile> <flower-profile> <a-profile> <b-profile> <c-profile>; do echo "== $p"; aws ec2 describe-route-tables --profile $p --filters Name=association.main,Values=true --query 'RouteTables[].Routes[].[DestinationCidrBlock,GatewayId||VpcPeeringConnectionId]' --output text; done
```

Expected: four active peerings in each of governance and Flower. Governance has 10.20, 10.31,
10.32 and 10.33 through peerings; Flower has 172.31, 10.31, 10.32 and 10.33; each hospital has
only 172.31 and 10.20. No hospital has a route to another hospital's range.

Then a sleeping copy of the server in the Flower account (it stops itself after an hour; it needs
the control token from step 6 to start):

```
cd src/infra/aws-l1b1/flower-43
terraform output -raw probe_task        # run the printed command
aws ecs list-tasks --profile <flower-profile> --cluster openhealth-l1b --output text
aws ecs execute-command --profile <flower-profile> --cluster openhealth-l1b --container flower-server --interactive --command /bin/sh --task <task id>
```

Inside the shell, with the host's private IP and the EFS mount target's IP (both from
central-18's outputs):

```
python3 - <<'EOF'
import socket
HOST, EFS = "<host IP>", "<EFS mount target IP>"
for host, port in [
    ("fc-hub.openhealth.internal", 8080),
    ("flower-server.flower.openhealth.internal", 8080),
    ("flower-server.flower.openhealth.internal", 8081),
    (HOST, 8443), (HOST, 9443), (HOST, 6379), (HOST, 8088), (HOST, 22), (EFS, 2049),
]:
    try:
        socket.create_connection((host, port), timeout=3).close()
        print("open  ", host, port)
    except OSError as e:
        print("closed", host, port, type(e).__name__)
EOF
```

`fc-hub` 8080 must be open (the host is up) and 2049 on the EFS open. The two `flower-server`
names resolve only once the server runs (step 8), so here they give `gaierror`; on any other name a
`gaierror` means DNS is not working. The verifier (8443), issuer (9443), Redis (6379), Hal (8088)
and SSH must be closed.

Now `/vault`: paste `terraform output -raw flower_43_vault` (from central-18) into
`flower-43/terraform.tfvars`, plan and apply, then run the probe task again. If it reaches
RUNNING, the cross-account mount works: ECS Exec in and run `df -h /vault`. If it stops with
`ResourceInitializationError`, read the reason:

```
aws ecs list-tasks --profile <flower-profile> --cluster openhealth-l1b --desired-status STOPPED --output text
aws ecs describe-tasks --profile <flower-profile> --cluster openhealth-l1b --tasks <task id> --query 'tasks[].[lastStatus,stoppedReason]' --output text
```

### Step 8: start the Flower server, then the clients

```
cd src/infra/aws-l1b1/flower-43
terraform plan -var desired_count=1 -out=tfplan
terraform apply tfplan
```

On the host:

```
getent hosts flower-server.flower.openhealth.internal
curl -s http://flower-server.flower.openhealth.internal:8081/health
curl -s http://127.0.0.1:8080/backend/list
```

Optionally, a sleeping client in each hospital account (`terraform output -raw probe_task` in
the workspace, ECS Exec as in step 7, same probe): only `fc-hub` 8080 and `flower-server` 8080
may be open; 8081, the EFS and every other port on the host must be closed. Stop each probe
with `aws ecs stop-task`.

```
cd src/infra/aws-l1b1/participant
terraform workspace select a
terraform plan -var-file=hospital-a.tfvars -var desired_count=1 -out=tfplan
terraform apply tfplan
```

(and `b`; `c` only for a Mode 1A run). Run the KYO ceremony (Test1A) or re-select the
envelope; the select response must show the bound execution keys. Then on the host:

```
export FLOWER_URL=http://flower-server.flower.openhealth.internal:8081
export FLOWER_EXEC="docker run --rm -i -v $HOME/openhealth-cdi/src/vfp-governance/verifier/vault:/vault -e FLOWER_URL fcac/flower-server:local"
./Test0B_delivery_preflight.sh <eid> 127.0.0.1
./Test1B_postEnvelope.sh <eid> local-pathmnist-ab-001 1800
./Test1C_verifyABRounds.sh <model run id> 10
./Test0C_delivery_regression.sh <eid> 127.0.0.1
```

Then Test1F (issue #7), from a workstation with the profiles for Hospital A, Hospital B and the Flower
account, and the host's ssh key loaded in `ssh-agent` (the script runs ssh with BatchMode). About 25
minutes; Hospital C stays at 0:

```
cd src/infra/aws-l1b1/tests
HOST=ubuntu@<host> PROFILE_A=<hospital A profile> PROFILE_B=<hospital B profile> PROFILE_F=<flower profile> \
  bash test1f-b1.sh <envelope_id>
```

Three runs, nothing restarted in between: (a) Hospital B stopped and a rogue in Hospital A's account
claiming B, signing with A's key, is refused and the run fails closed; (b) B still missing, no rogue: the
run fails after the server's `CLIENT_WAIT_TIMEOUT_SECONDS` (default 300 s); (c) B back: A and B complete.
On exit it stops the rogue and puts B's service back to its count. L1-B1 is GREEN only with Test1F GREEN.

## Park, unpark, destroy

**Park:** `desired_count` defaults to 0, so a plain plan and apply parks a root (the loop applies
without stopping to show the plan):

```
cd src/infra/aws-l1b1/participant && for w in a b c; do terraform workspace select $w && terraform plan -var-file=hospital-$w.tfvars -out=tfplan && terraform apply tfplan; done
cd ../flower-43 && terraform plan -out=tfplan && terraform apply tfplan
```

Then stop the host. Parked, the private zones cost $0.50 a month each and the secrets $0.40 a
month each; the rest costs nothing.

**Unpark:** start the host, then step 8 (`-var desired_count=1`, server first).

**Destroy:** each account destroys its own state, in this order: the three hospitals (their
requests, routes, zone links and secrets), then flower-43, then central-18. L1-A is not touched.

```
cd src/infra/aws-l1b1/participant && for w in a b c; do terraform workspace select $w && terraform destroy -var-file=hospital-$w.tfvars; done
cd ../flower-43 && terraform destroy -refresh=false
cd ../central-18 && terraform destroy -refresh=false
```

`-refresh=false`, because once the hospitals are gone their peering requests no longer exist, and
the lookups that accept them in flower-43 and central-18 would fail during a refresh.

The secrets have no recovery window, so their names can be reused at once.

**Back to L1-A:** park L1-B1, then on the host
`tofu apply -var flower_placement=ecs -var flower_backend_url=http://flower-server.openhealth.internal:8081`,
and in `../aws-l1a-flower-ecs` `terraform apply -var desired_count=1`. L1-A's server needs the
control token (`FLOWER_CONTROL_TOKEN`) and its clients their execution keys before a run: without
them the hub's bind is refused (503) and so is every client. **Back to L0:** `tofu apply`
with the defaults.

## Cost

Approximate London on-demand prices; check the pricing pages before relying on them.

- Flower server, Fargate 1 vCPU and 4 GB: about $0.07 an hour. Each client, 2 vCPU and 4 GB:
  about $0.11 an hour. Public IPv4: $0.005 an hour per running task. About $0.43 an hour for
  L1-B1 while running, plus the governance host.
- Peering has no hourly charge. Every subnet is in `euw2-az2`, so traffic between accounts stays
  in one zone.

## Known limitations

- Public task IPs and an internet gateway, no NAT, as in L1-A. No group admits anything from the
  internet. VPC endpoints for ECR, CloudWatch Logs and Secrets Manager (and an S3 gateway endpoint
  for image layers) would replace them; the clients still download MedMNIST when they start.
- Rules use CIDRs, not security-group references across accounts. Each client and the server
  have a dedicated /24 holding one service, and the hub is a /32.
- The cross-account `/vault` mount pins one EFS mount target (one zone), so there is no failover
  between zones. The Flower account can read all of `/vault`. Both go with B1's transitional
  relation.
- The Route 53 association authorisations (`grants` in `modules/peer-links`) are no longer
  needed once the associations exist.
- The host's own Terraform (`../aws-l0-host`) manages the instance's security groups; an apply of
  it would detach L1-A's and L1-B1's groups.
- With Secrets Manager, anything in a hospital's account that can read its secret holds that
  hospital's execution key. The keys are generated on the governance host and copied in, so the
  host holds every hospital's key until L1-B2 creates them in the hospitals' own accounts.
- ECS Exec is on for the services, which the probes use; anyone allowed `ecs:ExecuteCommand` in an
  account can read a running client's key. It should be off except when testing.
- Flower's gRPC (8080) and its control API (8081) are not encrypted; the traffic stays inside the
  peerings. TLS for Flower is deferred.
- The client image is several GB, so each Fargate start takes about 3 minutes.

## Not in this directory

- **L1-B2** (roadmap §6.5 to §6.7): hospital-owned source data in S3, execution keys created in
  each hospital's account, Flower-owned storage instead of the central EFS. It is a separate
  change.
- **The hub on ECS** (L1-C), **Bedrock**, and **GPU** clients.

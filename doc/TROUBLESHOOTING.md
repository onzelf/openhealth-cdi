# OpenHealth-CDI Troubleshooting Guide

## 1. Purpose of this document

This document provides operational troubleshooting procedures for the local OpenHealth-CDI Docker/OpenTofu reference implementation.

The first rule is simple. Identify the failing layer before changing state.

A container can be healthy while an nginx proxy still points to an obsolete Docker address. A Gatekeeper DENY can be correct even when the user expected execution. A model can exist while the currently selected governance envelope has no model run of its own. Hal can reach a host-published TCP edge while still lacking the cryptographic identity required to use it. An external reasoning request can fail while federation governance remains correct.

The troubleshooting sequence therefore separates:

```text
host and Docker runtime
compute backend
container topology
frontend and Hub
runtime envelope binding
TLS and mTLS edges
issuer and holder registration
ECT and DPoP
Gatekeeper admission
Flower/model execution
Hal isolation and reasoning
Mode 1B governance composition
```

## 2. Do not reset the federation as a first reaction

Creating a new governance envelope, deleting volumes, recreating every container, reminting every credential, or removing state can destroy the evidence needed to diagnose the failure.

Start with observation.

> ⚠️ **Troubleshooting rule**
>
> - Do not create a new envelope merely because an operation failed.
> - Do not delete persistent volumes merely because a container failed.
> - Do not broaden capability merely because a request returned DENY.
> - Do not rebuild the complete deployment to repair one component.
> - Diagnose the relation that failed first.

## 3. Local diagnostic variables

Run commands from the repository root unless a section explicitly changes directory.

For the standard single-host deployment:

```bash
export HOST_IP="${HOST_IP:-127.0.0.1}"
export EID=<active-envelope-id>

export CA=src/vfp-governance/verifier/certs/ca.crt
export HUB_CRT=src/vfp-governance/verifier/certs/hub.crt
export HUB_KEY=src/vfp-governance/verifier/certs/hub.key
export ADMIN_A_CRT=src/vfp-governance/verifier/certs/HospitalA-admin.crt
export ADMIN_A_KEY=src/vfp-governance/verifier/certs/HospitalA-admin.key
export ADMIN_B_CRT=src/vfp-governance/verifier/certs/HospitalB-admin.crt
export ADMIN_B_KEY=src/vfp-governance/verifier/certs/HospitalB-admin.key
```

`HOST_IP` identifies the host-published local edge used by diagnostic commands. It is not the OpenTofu `edge_bind_ip` variable.

## 4. First diagnostic snapshot

Before restarting anything:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'
```

Then inspect recent logs from the component nearest the failure:

```bash
docker logs --tail 100 fcac-frontend
docker logs --tail 100 fc-hub
docker logs --tail 100 verifier-proxy
docker logs --tail 100 verifier-app
docker logs --tail 100 issuer-proxy
docker logs --tail 100 issuer-hospitala
docker logs --tail 100 issuer-hospitalb
docker logs --tail 100 flower-server
docker logs --tail 100 flower-client-a
docker logs --tail 100 flower-client-b
docker logs --tail 100 flower-client-c
docker logs --tail 100 hal
```

Do not assume that the component reporting the error caused it.

## 5. Run the delivery preflight early

Before interpreting a demo, Mode 1B, or validation failure, run:

```bash
./src/tests/Test0B_delivery_preflight.sh "$EID" "$HOST_IP"
```

The preflight is read-only. It does not select an envelope, mint credentials, restart containers, retrain a model, alter policy, or modify governance state.

It checks the operational substrate required by the governed execution path, including:

```text
required containers
direct Hub reachability
selected envelope
Flower registration
Flower readiness
Flower envelope binding
frontend-to-Hub routing
verifier TLS health
issuer mTLS paths
Hal topology
Hal identity
reasoning credential presence
Gate 5A isolation
```

A GREEN preflight proves that these prerequisites are ready. It does not call the external reasoning provider and does not replace the Mode 1B conformance tests.

A RED preflight is diagnostic evidence. Repair the first failed layer.

## 6. Container running is not runtime ready

Keep these states separate:

```text
container running
≠ backend registered
≠ backend bound
≠ backend ready
```

A Flower server can be running and listening while PathMNIST is still being downloaded or initialized. Do not interpret a prediction timeout during that phase as a governance failure.

Inspect:

```bash
docker logs --tail 200 flower-server
docker logs --tail 200 fc-hub
```

and use the project readiness checks before testing model use.

## 7. Compute backend selection

OpenHealth-CDI v1.1.0 supports both CPU and CUDA execution.

Run:

```bash
./src/tests/Test0A_verifyDockerGPU.sh
```

The test determines whether a usable NVIDIA Docker runtime is available and writes the selected backend to:

```text
src/infra/tofu/compute.auto.tfvars
```

Inspect it with:

```bash
cat src/infra/tofu/compute.auto.tfvars
```

Expected values are:

```text
compute_backend = "cpu"
```

or:

```text
compute_backend = "cuda"
```

A machine without an NVIDIA GPU is a valid CPU deployment.

The portability rule is:

```text
no usable NVIDIA GPU
    → CPU

usable NVIDIA GPU and Docker GPU runtime
    → CUDA

CUDA selected but unavailable at runtime
    → fail rather than silently changing backend
```

## 8. Diagnose CUDA only when CUDA was selected

When `compute_backend = "cuda"`, check the stack in layers.

Host:

```bash
nvidia-smi
```

Docker:

```bash
docker run --rm --gpus all ubuntu:22.04 nvidia-smi
```

Flower runtime:

```bash
docker logs flower-client-a 2>&1 | grep -m1 -E 'CPU ready|CUDA ready'
docker logs flower-client-b 2>&1 | grep -m1 -E 'CPU ready|CUDA ready'
```

If the host works but Docker fails, investigate NVIDIA Container Toolkit.

If Docker works but a Flower client reports CUDA unavailable, investigate container GPU allocation or the Flower image rather than governance.

When CPU was selected, the expected runtime marker is:

```text
CPU ready:
```

## 9. Validate the selected compute runtime

After deployment or Flower-client rebuild:

```bash
src/tests/Test1C_verifyABRounds.sh
```

`Test1C` validates the A+B analytical runtime and artefacts against the selected CPU or CUDA backend.

`Test0C` does not replace `Test1C`. The two tests prove different things.

## 10. Fresh-clone bootstrap

A clean clone does not contain all local generated trust and holder state.

Run the repository bootstrap before deployment:

```bash
./src/tools/preflight_bootstrap.sh
```

After OpenTofu deployment, register the persistent human participants:

```bash
./src/tools/bootstrap_members.sh
```

The expected persistent human participants are:

```text
Audrey   Hospital A
Bob      Hospital B
Charlie  sponsored by Hospital A with Hospital C provenance
```

Do not compensate for missing bootstrap state by bypassing the issuer or minting directly at the verifier.

## 11. Holder-key ownership after bootstrap

Holder keys live beneath:

```text
src/vfp-governance/verifier/vault/holder_keys
```

If files exist but are inaccessible because they were created by a privileged process, inspect:

```bash
ls -la src/vfp-governance/verifier/vault/holder_keys
```

Repair ownership only when required:

```bash
sudo chown -R "$USER":"$(id -gn)" \
  src/vfp-governance/verifier/vault/holder_keys

chmod 700 \
  src/vfp-governance/verifier/vault/holder_keys
```

Do not regenerate holder identities merely because permissions are wrong.

## 12. Verify `verifier.local`

`verifier.local` is the stable TLS identity of the verifier. The local single-host deployment should resolve it to the host-published verifier edge.

Check:

```bash
getent hosts verifier.local
```

For the standard single-host deployment, `/etc/hosts` should contain:

```text
127.0.0.1 verifier.local
```

Failure to resolve `verifier.local` is a host-name configuration problem, not a verifier-policy failure.

Later diagnostic commands use `curl --resolve` deliberately. This bypasses normal host-name resolution and helps separate name-resolution failures from TLS and application failures.

## 13. The principal local routing trap

The most recurrent misleading local failure is stale nginx upstream resolution after an upstream Docker container has been recreated.

Docker can assign a new container IP when OpenTofu replaces a container. The current nginx configurations resolve Docker service names when their configuration is loaded and can continue using an old address after the upstream has changed.

Known examples:

```text
fc-hub replaced
    → fcac-frontend may retain the old Hub address

issuer-hospitala or issuer-hospitalb replaced
    → issuer-proxy may retain an old issuer address

verifier-app replaced
    → verifier-proxy may retain the old verifier-app address
```

OpenTofu dependency order does not imply nginx DNS refresh.

> 🔑 **Takeaway**
>
> If a service worked before an upstream container was replaced and then begins returning gateway or connection errors, suspect stale nginx upstream resolution before suspecting governance.

## 14. Diagnose frontend-to-Hub stale resolution

Compare direct Hub access:

```bash
curl -fsS \
  http://127.0.0.1:8080/administration/boundary |
  jq .
```

with the frontend path:

```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq .
```

Interpretation:

```text
direct Hub works
frontend path works
    → frontend-to-Hub path healthy

direct Hub works
frontend path fails
    → frontend nginx/upstream path suspect

direct Hub fails
frontend path fails
    → diagnose Hub first
```

If the Hub was recently recreated and only the frontend path fails:

```bash
docker restart fcac-frontend
```

Then repeat the frontend request.

Do not rebuild the frontend image merely to refresh nginx resolution.

## 15. Recognise stale nginx in logs

Typical indicators are:

```text
connect() failed
connection refused
upstream
502
Bad Gateway
```

Inspect:

```bash
docker logs --tail 200 fcac-frontend 2>&1 |
  grep -Ei 'upstream|connect|refused|502|bad gateway'

docker logs --tail 200 issuer-proxy 2>&1 |
  grep -Ei 'upstream|connect|refused|502|bad gateway'

docker logs --tail 200 verifier-proxy 2>&1 |
  grep -Ei 'upstream|connect|refused|502|bad gateway'
```

Compare an address reported by nginx with the current upstream container address:

```bash
docker inspect \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
  fc-hub
```

Restart only the affected proxy.

## 16. WSL port publication conflicts

On WSL, a stale Windows port-proxy rule can conflict with Docker port publication even when no Linux process appears to own the port.

If Docker reports an unexpected bind failure on a published port such as `8080`, inspect Linux first:

```bash
ss -ltnp | grep ':8080'
```

Then inspect Windows port-proxy state from an elevated PowerShell prompt:

```powershell
netsh interface portproxy show all
```

If a stale rule is confirmed, remove only that rule using the matching listen address and port.

Do not delete the complete port-proxy configuration as a generic repair.

## 17. Docker build DNS failures

If an image build fails while downloading packages, distinguish a Docker DNS problem from a project dependency problem.

Useful checks:

```bash
docker run --rm ubuntu:22.04 getent hosts archive.ubuntu.com
```

and:

```bash
docker run --rm python:3.11-slim getent hosts pypi.org
```

If name resolution fails in a generic container, repair Docker or host DNS before changing OpenHealth package versions.

## 18. Verify the selected envelope

Inspect:

```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq '{
    selected_envelope_id,
    envelopes: [
      .envelopes[] |
      {
        envelope_id,
        bound,
        expiry,
        model_available,
        model_run_id
      }
    ]
  }'
```

If the intended existing envelope is not selected:

```bash
curl -fsS \
  -X POST \
  "http://127.0.0.1:8082/api/administration/envelopes/${EID}/select" |
  jq .
```

Verify:

```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq -r '.selected_envelope_id'
```

The result should equal `$EID`.

## 19. Envelope binding lost after Hub or Flower replacement

Recreating `fc-hub` or `flower-server` does not invalidate an existing governance envelope, but it can remove the volatile runtime binding between that envelope and the Flower backend.

Typical signature:

```text
ACTIVE envelope exists
backend registered = true
flower server ready = true
registered clients present
selected_envelope_id = null
backend_bound = false
backend.bound_envelope = null
```

Do not create another KYO envelope.

Confirm the intended envelope remains ACTIVE:

```bash
curl -fsS \
  http://127.0.0.1:8080/administration/envelopes |
  jq .
```

Restore the existing binding:

```bash
curl -fsS \
  -X POST \
  "http://127.0.0.1:8080/administration/envelopes/${EID}/select" |
  jq .
```

Verify:

```bash
curl -fsS \
  http://127.0.0.1:8080/administration/envelopes |
  jq '{
    selected_envelope_id,
    backend_bound: (.backend.bound_envelope != null),
    bound_envelope: .backend.bound_envelope
  }'
```

Container replacement does not recreate governance. Re-selection only restores the runtime association between the existing envelope and the current backend instance.

## 20. Selected envelope and model provenance are different lifecycles

A current envelope may legitimately show:

```text
model_available = false
model_run_id = null
```

while an older trained model artefact still exists and is used under the current governance context.

Do not create a fake `run.json` to make a fresh envelope appear to have trained an existing model.

Do not retrain merely because `model_run_id` is null unless the intended operation genuinely requires a new model.

## 21. Verifier public TLS health

The verifier nginx exposes `/health` without requiring a client certificate.

Use:

```bash
curl -fsS \
  --resolve "verifier.local:8443:${HOST_IP}" \
  --cacert "$CA" \
  https://verifier.local:8443/health |
  jq .
```

If this fails, investigate:

```text
verifier-proxy
server certificate
project CA
HOST_IP
port 8443 publication
verifier-app upstream
```

If `/health` succeeds, public TLS and the verifier nginx backend path are at least partially operational.

## 22. Protected verifier access must remain protected

A request to `/admission/check` without a federation client certificate must not become an admitted application request.

```bash
curl -sS \
  --resolve "verifier.local:8443:${HOST_IP}" \
  --cacert "$CA" \
  -o /tmp/openhealth-verifier-deny.out \
  -w 'HTTP %{http_code}\n' \
  -X POST \
  https://verifier.local:8443/admission/check \
  -H 'content-type: application/json' \
  -d '{}'

cat /tmp/openhealth-verifier-deny.out
```

TLS rejection, HTTP 400 for a missing required SSL certificate, HTTP 401, or HTTP 403 can all represent correct rejection depending on the layer.

What must not happen is successful protected access.

## 23. Verify Hub mTLS identity

Send an intentionally incomplete request while presenting the Hub certificate:

```bash
curl -sS \
  --resolve "verifier.local:8443:${HOST_IP}" \
  --cacert "$CA" \
  --cert "$HUB_CRT" \
  --key "$HUB_KEY" \
  -o /tmp/openhealth-hub-mtls.out \
  -w 'HTTP %{http_code}\n' \
  -X POST \
  https://verifier.local:8443/admission/check \
  -H 'content-type: application/json' \
  -d '{}'

cat /tmp/openhealth-hub-mtls.out
```

The request body is deliberately incomplete. An application-level validation error is acceptable.

The important distinction is that the request passes the Hub identity check.

## 24. Verify issuer mTLS

Hospital A:

```bash
curl -fsS \
  --resolve "issuer-hospitala.local:9443:${HOST_IP}" \
  --cacert "$CA" \
  --cert "$ADMIN_A_CRT" \
  --key "$ADMIN_A_KEY" \
  https://issuer-hospitala.local:9443/members |
  jq .
```

Hospital B:

```bash
curl -fsS \
  --resolve "issuer-hospitalb.local:9443:${HOST_IP}" \
  --cacert "$CA" \
  --cert "$ADMIN_B_CRT" \
  --key "$ADMIN_B_KEY" \
  https://issuer-hospitalb.local:9443/members |
  jq .
```

These probes exercise the host-published issuer mTLS boundaries rather than bypassing them.

If they fail immediately after an issuer container was recreated, inspect or restart `issuer-proxy` before changing issuer configuration.

## 25. Issuer returns verifier-related errors

If minting reports errors such as:

```text
verifier_error
issuer_verifier_ca_unavailable
issuer_verifier_tls_verification_disabled
```

inspect:

```bash
docker logs --tail 200 issuer-hospitala
docker logs --tail 200 issuer-hospitalb
```

Check the mounted CA:

```bash
docker exec issuer-hospitala \
  test -s /run/certs/ca.crt &&
  echo "Hospital A CA present"

docker exec issuer-hospitalb \
  test -s /run/certs/ca.crt &&
  echo "Hospital B CA present"
```

Check configuration:

```bash
docker inspect issuer-hospitala |
  jq -r '.[0].Config.Env[]' |
  grep -E '^(VERIFY_TLS|CA_CRT|VERIFIER_URL)='
```

Expected semantics:

```text
VERIFY_TLS=1
CA_CRT points to an existing CA file
VERIFIER_URL uses https
```

Do not repair a verifier connection by disabling TLS verification.

## 26. ECT missing or expired

Inspect holder state:

```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq '.holders[] |
      {
        principal,
        organization,
        enrollment_status,
        ect_status,
        expires_at
      }'
```

If a legitimate holder is enrolled but its ECT is not ready, mint through the application issuer path:

```bash
curl -fsS \
  -X POST \
  "http://127.0.0.1:8082/api/administration/holders/Audrey/mint-ect" \
  -H 'content-type: application/json' \
  -d "$(jq -nc \
      --arg envelope "$EID" \
      '{envelope_id:$envelope}')" |
  jq .
```

Replace `Audrey` with the intended holder.

Do not add caller-selected capability or sponsorship fields. Effective authority remains issuer-owned.

## 27. Issuer rejects `profile` or `sponsors`

That rejection is correct.

The mint API deliberately forbids caller-selected fields that could let the caller choose its own capability or sponsorship.

Use only the holder identity and envelope through the supported issuer path.

An HTTP 422 caused by forbidden authority-selection fields is boundary enforcement, not a minting defect.

## 28. Unknown holder during minting

An issuer result containing:

```text
unknown_sub
```

means the holder does not have a valid registration in that issuer registry.

For a fresh deployment, rerun the post-deployment member bootstrap if registration was never completed:

```bash
./src/tools/bootstrap_members.sh
```

Do not bypass organisation registration by minting directly against the verifier.

Relevant conformance tests include:

```bash
cd src/tests
ISSUER_IP="$HOST_IP" ./Test2F_issuer_registration_boundary.sh
```

For Hal:

```bash
ISSUER_IP="$HOST_IP" VERIFIER_IP="$HOST_IP" \
  ./Test5C_agent_credential_admission.sh "$EID"
```

For Charlie:

```bash
ISSUER_IP="$HOST_IP" \
  ./Test3F_mode1a_guest_admission.sh "$EID"
```

## 29. Hal identity changed

Hal stores its persistent holder identity in:

```text
hal-identity
```

Inspect the current JKT:

```bash
docker exec hal \
  cat /var/lib/hal/identity/holder.jkt
```

Inspect identity files:

```bash
docker exec hal \
  ls -l /var/lib/hal/identity
```

If the `hal-identity` volume was deleted, Hal creates a new key and therefore a new JKT. An older Hospital A registration then identifies a different cryptographic holder.

Do not silently overwrite the previous registration during diagnosis. Establish why the identity changed.

## 30. Governed direct inference probe

For Audrey and mucus:

```bash
curl -fsS \
  -X POST \
  http://127.0.0.1:8082/api/user/inference \
  -H 'content-type: application/json' \
  -d "$(jq -nc \
      --arg principal "Audrey" \
      --arg envelope "$EID" \
      --arg tissue "mucus" \
      '{
        principal:$principal,
        envelope_id:$envelope,
        requested_tissue:$tissue,
        topk:3
      }')" |
  jq '{
    request,
    admission,
    executed,
    model_run_id
  }'
```

For the current Audrey source policy, mucus should follow the allowed direct-source path when prerequisites are valid.

## 31. Use a known DENY

A negative request can be more informative than a positive one.

For Audrey requesting cancer-related source data:

```bash
curl -fsS \
  -X POST \
  http://127.0.0.1:8082/api/user/inference \
  -H 'content-type: application/json' \
  -d "$(jq -nc \
      --arg principal "Audrey" \
      --arg envelope "$EID" \
      --arg tissue "colorectal_adenocarcinoma_epithelium" \
      '{
        principal:$principal,
        envelope_id:$envelope,
        requested_tissue:$tissue,
        topk:3
      }')" |
  jq '{
    admission,
    executed,
    model_run_id
  }'
```

The expected direct-source result for Audrey is DENY with no direct source execution.

In Mode 1B, that source DENY can be the beginning of the separately governed derivative path. It is not itself a request to Hal.

## 32. Reserved tissue diagnostic

A reserved class provides another negative probe.

```bash
curl -fsS \
  -X POST \
  http://127.0.0.1:8082/api/user/inference \
  -H 'content-type: application/json' \
  -d "$(jq -nc \
      --arg principal "Audrey" \
      --arg envelope "$EID" \
      --arg tissue "background" \
      '{
        principal:$principal,
        envelope_id:$envelope,
        requested_tissue:$tissue,
        topk:3
      }')" |
  jq '{
    admission,
    executed
  }'
```

Expected semantics:

```text
DENY
reason = reserved_tissue
executed = false
```

## 33. A DENY is not automatically a failure

Expected DENY results include:

```text
scope exceeded
reserved tissue
ordinary model query attempted with Hal's bounded-agent capability
training contribution attempted with Hal's bounded-agent capability
model query attempted with Charlie's guest-contributor capability
replayed DPoP
stale DPoP
future-dated DPoP
privileged governance operation attempted by Hal
```

Do not troubleshoot an expected DENY as if the platform were broken.

Check whether the reason is correct and whether execution remained blocked.

## 34. DPoP replay and freshness

Replay:

```bash
cd src/tests
./Test4A_dpop_replay_protection.sh "$EID"
```

Freshness:

```bash
./Test4B_dpop_iat_freshness.sh "$EID"
```

For time errors, inspect:

```bash
date -u
docker exec verifier-app date -u
docker exec holder-signer date -u
docker exec hal date -u
```

Do not widen the freshness window merely to conceal a clock problem.

## 35. KYO ceremony does not complete

The A+B governance envelope requires both founding approvals.

A pending envelope after only one approval is correct.

If a verification code expired, obtain a fresh short-lived verification session rather than changing quorum.

Controlled reproduction:

```bash
cd src/tests
./Test1A_createEnvelope.sh
```

Do not reduce the two-of-two policy to make the ceremony complete.

## 36. Flower training does not start

Inspect:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}' |
  grep -E 'fc-hub|flower-server|flower-client'

docker logs --tail 200 fc-hub
docker logs --tail 200 flower-server
docker logs --tail 200 flower-client-a
docker logs --tail 200 flower-client-b
docker logs --tail 200 flower-client-c
```

For A+B, the expected registered-client requirement is two.

Mode 1A uses Hospital C as the additional contribution site.

Do not infer federation membership directly from Flower registration. Flower connectivity is execution state. Governance standing is defined separately.

## 37. Model exists but inference fails

Separate model existence from governance admission.

Run the non-governed analytical smoke test:

```bash
cd src/tests
./Test1D_validate_non_governed.sh
```

If direct model evaluation fails, investigate analytical state or the model artefact.

If it succeeds but governed inference fails, inspect:

```text
selected envelope
ECT state
holder proof
Gatekeeper decision
Hub orchestration
```

## 38. Model changes during an admission-only test

Some tests intentionally exercise admission without executing Flower.

If an admission-only regression hashes the model before and after its checks, a hash change is not harmless retraining. It indicates unexpected execution or artefact mutation.

Preserve the distinction between governance admission and analytical execution.

## 39. Diagnose Hal isolation with the executable test

Run:

```bash
cd src/tests
LAN_IP="$HOST_IP" ./Test5A_agent_isolation.sh
```

`LAN_IP` is retained here as the test's host-edge diagnostic variable. It is not an OpenTofu `lan_ip` input.

The intended topology is:

```text
Hal → fc-hub:8080             reachable
Hal → Redis                   unreachable
Hal → holder-signer           unreachable
Hal → verifier-app            unreachable
Hal → verifier-proxy internal unreachable
Hal → issuer containers       unreachable
Hal → issuer-proxy internal   unreachable
Hal → Flower internals        unreachable
```

Hal should be attached only to `agent-edge`.

The Hub should be dual-homed on `agent-edge` and `fc`.

## 40. Host-published mTLS edge can be routable from Hal

A successful TCP connection to a host-published verifier or issuer edge does not establish federation authority.

The local architecture separates routing from cryptographic usability.

A result such as:

```text
TLS rejection
400 No required SSL certificate was sent
401
403
```

is consistent with the intended boundary when Hal lacks an accepted federation client certificate.

> ⚠️ **Interpretation constraint**
>
> `TCP connection succeeded` does not mean `federation authority obtained`.

## 41. Hal contains unexpected credentials

Inspect mounts:

```bash
docker inspect hal |
  jq '.[0].Mounts |
      map({
        Type,
        Source,
        Destination,
        RW
      })'
```

Hal should not receive:

```text
human holder-key vault
shared verifier certificate directory
governance evidence private key
verifier vault
```

If any of these appear, treat the condition as an isolation defect.

## 42. Hal reasoning credential is missing

The expected local development secret is:

```text
secrets/.env
```

It must be a regular file, not a directory.

Check without exposing the secret:

```bash
test -f secrets/.env &&
  echo "OpenAI environment file is a regular file"
```

Confirm that a non-empty key is configured without printing it:

```bash
grep -q '^OPENAI_API_KEY=.' secrets/.env &&
  echo "OpenAI API key configured"
```

Inspect the Hal mount:

```bash
docker inspect hal |
  jq '.[0].Mounts'
```

Then verify the mounted file inside the container:

```bash
docker exec hal \
  test -s /run/secrets/openai.env &&
  echo "reasoning credential file present"
```

Do not print the credential into logs, screenshots, tickets, or shell history.

## 43. Hal cannot reach the reasoning provider

Inspect:

```bash
docker logs --tail 200 hal
```

Relevant errors include:

```text
openai_api_key_not_configured
openai_unreachable
openai_http_<status>
openai_response_has_no_text
```

Interpret them separately.

```text
openai_api_key_not_configured
    → local secret provisioning

openai_unreachable
    → network, DNS, TLS, or provider reachability

openai_http_401
    → provider credential rejection
```

An external provider error is not a Gatekeeper failure.

The same diagnostic separation applies after porting. External reasoning-provider availability and credentials remain distinct from federation governance.

## 44. Reasoning provider returns invalid JSON

Hal validates the returned reasoning response.

Invalid JSON or an action outside the supplied action set causes Hal to fall back to `refuse`.

This is an execution safeguard.

It is not a Gatekeeper DENY and should not be diagnosed as a capability failure.

## 45. Mode 1B contextual test fails

Run:

```bash
cd src/tests
ISSUER_IP="$HOST_IP" \
VERIFIER_IP="$HOST_IP" \
./Test5E_mode1b_contextual_agent.sh "$EID"
```

Classify the failing relation before changing anything:

```text
source decision wrong
    → requester capability or Gatekeeper policy

Hal cannot reason
    → external reasoning provider

unbind unexpectedly denied
    → Hal bounded capability or requested scope

consume(W) unexpectedly denied
    → requester derivative authority

correct decisions but wrong representation
    → Hub orchestration or Hal execution
```

One user-visible request can contain several independent governance decisions.

## 46. Audrey and Bob are intentionally asymmetric

The contextual scenario expects:

```text
Audrey + mucus
    source ALLOW

Audrey + colorectal adenocarcinoma epithelium
    source DENY
    derivative path available through Mode 1B composition

Bob + colorectal adenocarcinoma epithelium
    source ALLOW

Bob + mucus
    source DENY
    derivative path available through Mode 1B composition
```

Do not normalize Audrey and Bob to identical source authority. Their asymmetry is part of the scenario.

## 47. Unbind succeeds but derivative is not released

A successful Hal `unbind` is not sufficient for release.

The requester must also be admitted for the derivative-consumption relation.

Inspect separately:

```text
source admission
Hal reasoning
Hal admission
unbind admission
governed derivative W
consume(W) admission
release
```

If Unbind is ALLOW but Consume W is DENY, investigate requester derivative authority.

Do not make the Hub release the derivative merely because transformation succeeded.

> 🔑 **Takeaway**
>
> Transformation and release are separate authority boundaries.

## 48. Dashboard and evidence disagree

The dashboard is an operational presentation layer.

Signed Gatekeeper evidence is authoritative for admission decisions.

Inspect decision records:

```bash
find \
  src/vfp-governance/verifier/state/events/decisions \
  -maxdepth 1 \
  -type f \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' 2>/dev/null |
  sort
```

Use the corresponding executable conformance test rather than editing evidence manually.

For the shared governance substrate:

```bash
cd src/tests
ISSUER_IP="$HOST_IP" \
./Test2E_fcac_conformance.sh "$EID"
```

## 49. A test fails after another test changed state

The suite is stateful.

Determine whether the preceding operation:

```text
created an envelope
selected another envelope
minted or expired an ECT
registered a holder
started a training run
recreated a container
changed a persistent identity
```

Check the current state directly:

```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq .
```

Do not reconstruct current state from memory.

## 50. OpenTofu and Docker disagree

Inspect OpenTofu state:

```bash
cd src/infra/tofu
tofu state list
```

Inspect the plan:

```bash
tofu plan
```

Compare with:

```bash
docker ps -a
```

The selected compute backend is loaded from:

```text
compute.auto.tfvars
```

The host publication interface is controlled independently by `edge_bind_ip`.

There is no v1.1.0 requirement to pass a `lan_ip` variable to OpenTofu.

## 51. Rebuild only the changed component

Use targeted replacement rather than rebuilding the complete deployment.

For example, after a Flower-client runtime change:

```bash
cd src/infra/tofu

tofu apply -auto-approve \
  -replace=docker_image.flower_client \
  -replace=docker_container.flower_client_a \
  -replace=docker_container.flower_client_b \
  -replace=docker_container.flower_client_c
```

After replacing an upstream service, remember the nginx-resolution issue described earlier.

## 52. Do not normalize TLS troubleshooting with `curl -k`

`curl -k` disables server-certificate verification.

It can be useful for narrow diagnosis, but it must not become the documented operational path.

If a request works only with:

```bash
curl -k
```

while the equivalent request fails with:

```bash
--cacert "$CA"
```

the TLS trust configuration remains broken.

Repair certificate trust.

## 53. Use conformance tests after operational repair

Ad hoc probes locate the failing layer.

The executable tests re-establish the invariant after repair.

Useful mapping:

```text
compute/runtime
    Test0A / Test1C

delivery substrate
    Test0B

final Mode 1B delivery regression
    Test0C

issuer authority
    Test2C / Test2D / Test2F

signed governance evidence
    Test2E

dashboard policy path
    Test3E

guest participation
    Test3F / Test3G

DPoP replay and freshness
    Test4A / Test4B

sponsorship
    Test4C

Hal isolation
    Test5A

Hal credential
    Test5C

Mode 1B decision plane
    Test5D

Mode 1B contextual composition
    Test5E
```

Troubleshooting proves that the system is reachable again. Conformance tests prove that it still behaves as intended.

## 54. Final validation after repair

For a complete local v1.1.0 validation:

```bash
./src/tests/Test0B_delivery_preflight.sh "$EID" "$HOST_IP"
```

Then validate the selected A+B compute runtime:

```bash
./src/tests/Test1C_verifyABRounds.sh
```

Then run the Mode 1B delivery regression:

```bash
./src/tests/Test0C_delivery_regression.sh "$EID" "$HOST_IP"
```

The expected final result from `Test0C` is:

```text
ALL DELIVERY GATES GREEN
```

`Test0C` and `Test1C` remain separate acceptance checks.

## 55. Troubleshooting order

Use this sequence:

```text
1. Preserve current state.
2. Inspect running containers and logs.
3. Run Test0B delivery preflight.
4. Confirm the selected CPU or CUDA backend.
5. Check direct Hub.
6. Check frontend-to-Hub.
7. If only a proxy path fails after replacement, restart that proxy.
8. Confirm the selected governance envelope.
9. Confirm Flower registration, readiness, and envelope binding.
10. Confirm holder registration and ECT readiness.
11. Check verifier TLS and mTLS identity paths.
12. Exercise one known ALLOW and one known DENY.
13. If execution fails after ALLOW, inspect Flower, model, and compute runtime.
14. For Mode 1B, separate Hal isolation, credential, reasoning, Unbind, Consume W, and release.
15. Run the corresponding conformance test after repair.
```

This sequence minimizes destructive changes and isolates the failure domain quickly.

## 56. Portability rule

Operational recovery must not depend on prior ChatGPT, Claude, OpenAI-account, Anthropic-account, or developer-conversation context.

Those histories can accelerate diagnosis when an original developer is present, but they are not part of the deployable system.

The repository, bootstrap procedures, executable tests, logs, and this troubleshooting guide must contain enough information for an engineer without that conversational context to identify the failing layer and apply the documented recovery procedure.

## 57. Summary

The central operational lesson is that apparently architectural failures often originate in simpler platform state.

A recreated upstream container can leave nginx pointing to an obsolete Docker address. A running Flower container can still be unready. A fresh clone can lack local holder state. A CPU-only host can be completely valid. An external reasoning-provider failure can coexist with correct federation governance.

The reverse is equally important. A technically successful TCP connection or computation does not prove correct federation behavior. Expected DENY decisions, mTLS rejection, DPoP rejection, bounded-agent isolation, Unbind authority, and derivative-consumption authority are all distinct relations.

Effective troubleshooting therefore preserves state, isolates layers, separates routing from authority, separates analytical execution from governance admission, and uses the executable tests to re-establish the relevant invariant after repair.

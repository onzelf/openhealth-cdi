# OpenHealth-CDI Troubleshooting Guide
## 1. Purpose of this document
This document provides operational troubleshooting procedures for the local OpenHealth-CDI Docker/OpenTofu reference implementation. It is intended for an engineer who did not participate in development and therefore explains not only which commands are useful but also how to interpret their results.
Troubleshooting OpenHealth-CDI requires separating several failure domains. A container can be healthy while its proxy still points to an obsolete Docker address. A Gatekeeper DENY can be correct even though the user expected execution. A model can exist while the currently selected governance envelope has no model run of its own. Hal can reach a host-published TCP endpoint while still correctly lacking the identity required to use that endpoint. An LLM call can fail while federation governance remains completely correct.
The first objective is therefore to identify **which layer failed before changing state**.
## 2. Do not reset the federation as a first reaction
Creating a new governance envelope, deleting volumes, recreating every container, reminting every credential, or removing state can make diagnosis substantially harder. These actions alter the state that explains the failure.
Start with observation. Determine whether the problem belongs to the browser/frontend path, Hub, proxy resolution, mTLS boundary, issuer, capability, holder proof, Gatekeeper, Flower runtime, model state, Hal execution path, or external reasoning runtime.
Only then modify the affected component.
> ⚠️ **Troubleshooting rule**
> - Do not create a new envelope merely because an operation failed.
> - Do not delete persistent volumes merely because a container failed.
> - Do not broaden capability merely because a request returned DENY.
> - Diagnose the relation that failed first.
## 3. Define the local diagnostic variables
Most commands in this guide assume:
```bash
export HOST_IP=<host-ip>
export EID=<active-envelope-id>

export CA=src/vfp-governance/verifier/certs/ca.crt
export HUB_CRT=src/vfp-governance/verifier/certs/hub.crt
export HUB_KEY=src/vfp-governance/verifier/certs/hub.key
export ADMIN_A_CRT=src/vfp-governance/verifier/certs/HospitalA-admin.crt
export ADMIN_A_KEY=src/vfp-governance/verifier/certs/HospitalA-admin.key
export ADMIN_B_CRT=src/vfp-governance/verifier/certs/HospitalB-admin.crt
export ADMIN_B_KEY=src/vfp-governance/verifier/certs/HospitalB-admin.key
```
Run these commands from the repository root unless a section explicitly changes directory.
## 4. First diagnostic snapshot
Before restarting anything, capture the current deployment:
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
Do not assume that the component reporting the error is the component that caused it. nginx, for example, may report an upstream failure caused by replacement of another container.
## 5. The most important local failure encountered during development
The most recurrent misleading failure encountered during development was **stale nginx upstream resolution after an upstream Docker container had been recreated**.
Docker can assign a new container IP address when OpenTofu replaces a container. The current nginx configurations refer to Docker service names through ordinary `proxy_pass` directives. nginx resolves those names when its configuration is loaded and can continue using the old address after the upstream container has been replaced.
This produced two important real failures during development.
After an issuer container was recreated, `issuer-proxy` continued attempting to use the old issuer address. The issuer itself was healthy, but requests through the mTLS issuer edge failed until `issuer-proxy` was restarted.
After the Hub was recreated, the frontend nginx continued using the previous Hub address. The Hub itself was healthy and reachable directly on its loopback port, but the dashboard API failed until `fcac-frontend` was restarted.
OpenTofu `depends_on` controls creation order. It does **not** imply that a dependent nginx container will automatically be recreated when an upstream container receives a new Docker address.
> 🔑 **Takeaway**
> - If a service worked before an upstream container was replaced and suddenly returns gateway or connection errors afterwards, suspect **stale nginx upstream resolution before suspecting governance**.
## 6. Diagnose frontend-to-Hub stale DNS
The frontend exposes the Hub beneath `/api/`, while the Hub is also available directly on local loopback.
Compare the same operation through both paths:
```bash
curl -fsS \
  http://127.0.0.1:8080/administration/boundary |
  jq .
```
Then:
```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq .
```
Interpretation:
```text
direct Hub works
frontend path works
    → frontend-to-Hub path is healthy

direct Hub works
frontend path fails
    → frontend nginx/upstream path is the prime suspect

direct Hub fails
frontend path fails
    → diagnose Hub before frontend
```
If the Hub was recently recreated and only the frontend path fails:
```bash
docker restart fcac-frontend
```
Then repeat:
```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq .
```
Do not rebuild the frontend image merely to refresh nginx DNS.
## 7. Recognising stale nginx in logs
A stale nginx upstream commonly produces messages containing:
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
```
For the issuer:
```bash
docker logs --tail 200 issuer-proxy 2>&1 |
  grep -Ei 'upstream|connect|refused|502|bad gateway'
```
For the verifier:
```bash
docker logs --tail 200 verifier-proxy 2>&1 |
  grep -Ei 'upstream|connect|refused|502|bad gateway'
```
If the log identifies an upstream IP address, compare it with the current container address:
```bash
docker inspect \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
  fc-hub
```
or:
```bash
docker inspect \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
  issuer-hospitala
```
A proxy using an address belonging to the previous container instance requires proxy restart.
## 8. Known proxy restart relationships
After replacing:
```text
fc-hub
```
restart:
```bash
docker restart fcac-frontend
```
After replacing:
```text
issuer-hospitala
issuer-hospitalb
```
restart:
```bash
docker restart issuer-proxy
```
After replacing:
```text
verifier-app
```
restart:
```bash
docker restart verifier-proxy
```
Restart only the relevant proxy unless there is evidence that another component also requires intervention.
This local weakness should disappear in the AWS port through managed service discovery rather than being reproduced deliberately.
## 9. Quick dashboard API health check
The fastest useful application-level check is:
```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq '{
    selected_envelope_id,
    envelopes,
    holders
  }'
```
This confirms that:
```text
frontend nginx is reachable
frontend nginx can reach the Hub
Hub administration API is responding
governance-envelope state can be read
holder state can be read
```
It does not prove that the mTLS Gatekeeper path is healthy or that a particular holder is authorised.
## 10. Quick Hub-only check
To separate Hub health from the frontend proxy:
```bash
curl -fsS \
  http://127.0.0.1:8080/administration/boundary |
  jq .
```
If this works while the corresponding `8082/api` call fails, the Hub is not the immediate problem.
## 11. Verify the selected envelope
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
If the wrong envelope is selected and the intended envelope is already valid:
```bash
curl -fsS \
  -X POST \
  "http://127.0.0.1:8082/api/administration/envelopes/${EID}/select" |
  jq .
```
Then verify:
```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq -r '.selected_envelope_id'
```
The result should equal `$EID`.
## 12. A selected envelope is not necessarily a model-producing envelope
A current envelope may legitimately show:
```text
model_available = false
model_run_id = null
```
while an older trained model artefact still exists and can be governed for a later operation.
This is not automatically a corruption.
The governance-envelope lifecycle and model-run lifecycle are independent. A newly selected envelope governs the current operation but does not become the historical training provenance of an older model.
> ⚠️ **Interpretation constraint**
> - Do not create a fake `run.json` merely to make a fresh envelope appear to have trained an existing model.
> - Do not retrain merely because `model_run_id` is null unless the intended operation genuinely requires a model associated with that envelope.
## 13. Check verifier public health
The verifier nginx exposes `/health` without requiring a client certificate.
Use the logical TLS name while directing it to the local host address:
```bash
curl -fsS \
  --resolve "verifier.local:8443:${HOST_IP}" \
  --cacert "$CA" \
  https://verifier.local:8443/health |
  jq .
```
If this fails, investigate:
```text
verifier-proxy container
server certificate
CA path
HOST_IP
port 8443 publication
verifier-app upstream
```
If `/health` works, nginx TLS and its backend path are at least partially operational.
## 14. Verify that protected verifier access is actually protected
A request to `/admission/check` without a federation client certificate should not become an admitted application request.
Diagnostic command:
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
Depending on where rejection occurs, an unauthenticated probe can produce TLS rejection, HTTP 400 indicating that a required SSL certificate was not supplied, HTTP 401, or HTTP 403.
What must **not** happen is successful protected access.
## 15. Verify that the Hub certificate is accepted
A useful mTLS diagnostic is to send an intentionally incomplete application request while presenting the Hub certificate:
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
The request body is deliberately incomplete. An application-level validation error is therefore acceptable for this diagnostic.
The important distinction is that the request should pass the Hub identity check rather than fail as an unauthenticated or wrong-identity caller.
## 16. Verify Hospital A issuer mTLS
The issuer proxy requires client certificates globally.
Check Hospital A using its administrator certificate:
```bash
curl -fsS \
  --resolve "issuer-hospitala.local:9443:${HOST_IP}" \
  --cacert "$CA" \
  --cert "$ADMIN_A_CRT" \
  --key "$ADMIN_A_KEY" \
  https://issuer-hospitala.local:9443/members |
  jq .
```
Check the configured capability names:
```bash
curl -fsS \
  --resolve "issuer-hospitala.local:9443:${HOST_IP}" \
  --cacert "$CA" \
  --cert "$ADMIN_A_CRT" \
  --key "$ADMIN_A_KEY" \
  https://issuer-hospitala.local:9443/rights |
  jq .
```
If these fail immediately after `issuer-hospitala` was recreated, inspect `issuer-proxy` before changing entitlement or certificate configuration.
## 17. Verify Hospital B issuer mTLS
Equivalent Hospital B checks are:
```bash
curl -fsS \
  --resolve "issuer-hospitalb.local:9443:${HOST_IP}" \
  --cacert "$CA" \
  --cert "$ADMIN_B_CRT" \
  --key "$ADMIN_B_KEY" \
  https://issuer-hospitalb.local:9443/members |
  jq .
```
and:
```bash
curl -fsS \
  --resolve "issuer-hospitalb.local:9443:${HOST_IP}" \
  --cacert "$CA" \
  --cert "$ADMIN_B_CRT" \
  --key "$ADMIN_B_KEY" \
  https://issuer-hospitalb.local:9443/rights |
  jq .
```
These commands exercise the host-published mTLS issuer boundary rather than bypassing it.
## 18. Issuer returns 502 during minting
The issuer calls the verifier through:
```text
https://verifier-proxy:8443
```
and requires TLS verification.
If minting reports:
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
Expected semantics are:
```text
VERIFY_TLS=1
CA_CRT points to an existing CA file
VERIFIER_URL uses https
```
Do not "repair" a verifier connection by disabling TLS verification.
## 19. ECT is missing or expired
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
Do not add a capability profile to this request. The issuer owns entitlement assignment.
## 20. Issuer rejects `profile` or `sponsors`
That rejection is correct.
The mint API deliberately forbids caller-selected fields that would let the caller choose its own capability or sponsorship.
A response such as HTTP 422 after adding `profile` or `sponsors` is evidence that the boundary is functioning.
Use:
```text
sub
envelope_id
```
through the issuer path and allow the issuer configuration to resolve effective authority.
## 21. Unknown holder during minting
An issuer response containing:
```text
unknown_sub
```
means the holder does not have a registration in that issuer's registry.
Do not bypass this by minting directly against the verifier.
For normal operation, resolve the holder-registration problem through the organisation issuer.
Relevant conformance tests are:
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
## 22. Hal registration no longer matches Hal's identity
Hal stores its persistent holder identity in the Docker volume:
```text
hal-identity
```
Inspect the current JKT:
```bash
docker exec hal \
  cat /var/lib/hal/identity/holder.jkt
```
Inspect the identity files:
```bash
docker exec hal \
  ls -l /var/lib/hal/identity
```
The private holder key should exist and use restrictive permissions.
If the `hal-identity` volume was deleted, Hal will create a new key and therefore a new JKT. An older Hospital A registry entry then represents a different cryptographic holder.
Do not silently overwrite the old registration during diagnosis. Establish why the identity changed first.
## 23. Governed inference with `curl`
A useful end-to-end application probe is the same request used by the dashboard policy-scope test.
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
For the current Audrey policy, `mucus` should follow the allowed direct source path when all prerequisites are valid.
## 24. Use a known DENY to test the governance path
A negative request can be more informative than a positive one.
For Audrey requesting cancer-associated stroma:
```bash
curl -fsS \
  -X POST \
  http://127.0.0.1:8082/api/user/inference \
  -H 'content-type: application/json' \
  -d "$(jq -nc \
      --arg principal "Audrey" \
      --arg envelope "$EID" \
      --arg tissue "cancer_associated_stroma" \
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
The expected direct-source result is a DENY caused by scope, with:
```text
executed = false
```
If the request is denied but `executed` is true, treat that as an architecture defect rather than an ordinary application error.
## 25. Reserved tissue diagnostic
The reserved `background` class provides another useful negative probe:
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
Expected governance semantics are:
```text
DENY
reason = reserved_tissue
executed = false
```
## 26. A DENY is not necessarily a failure
OpenHealth-CDI uses DENY as executable evidence.
Examples of expected DENY results include:
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
The important diagnostic questions are whether the reason is correct and whether execution remained blocked.
## 27. DPoP replay errors
A response containing:
```text
dpop_replay
```
means the same holder proof was used more than once.
That is expected rejection.
Generate a fresh proof rather than reusing the previous JWT.
Verify the behaviour with:
```bash
cd src/tests
./Test4A_dpop_replay_protection.sh "$EID"
```
The test confirms that one fresh proof succeeds, replay of the same proof fails, and another newly generated proof succeeds.
## 28. DPoP freshness errors
Errors:
```text
dpop_iat_stale
dpop_iat_future
```
indicate that holder-proof time lies outside the Gatekeeper freshness window.
First check host time:
```bash
date -u
```
Then check container time:
```bash
docker exec verifier-app date -u
docker exec holder-signer date -u
docker exec hal date -u
```
The containers use the host kernel clock, so substantial differences usually indicate host-time configuration rather than container-local drift.
Verify the intended behaviour with:
```bash
cd src/tests
./Test4B_dpop_iat_freshness.sh "$EID"
```
Do not widen the freshness window merely to conceal a clock problem.
## 29. KYO ceremony does not complete
The A+B governance envelope requires both founding approvals.
If a verification code has expired, start or obtain a fresh short-lived verification session rather than modifying quorum.
If one organisation has approved and the second has not, the envelope should remain pending.
The required two-of-two quorum is policy-owned. Reducing it to make the ceremony complete would change governance rather than troubleshoot execution.
Use:
```bash
cd src/tests
./Test1A_createEnvelope.sh
```
for a controlled reproduction of the full ceremony.
## 30. Flower training does not start
Before investigating training code, check the Hub and backend state:
```bash
docker ps --format 'table {{.Names}}\t{{.Status}}' |
  grep -E 'fc-hub|flower-server|flower-client'
```
Inspect:
```bash
docker logs --tail 200 fc-hub
docker logs --tail 200 flower-server
docker logs --tail 200 flower-client-a
docker logs --tail 200 flower-client-b
docker logs --tail 200 flower-client-c
```
For A+B, the expected registered-client requirement is two.
Mode 1A uses Hospital C as the additional contribution site.
Do not infer federation membership directly from Flower registration. Flower connectivity is execution state, while governance standing is defined separately.
## 31. GPU failures
Check host GPU first:
```bash
nvidia-smi
```
Then Docker GPU exposure:
```bash
docker run --rm --gpus all ubuntu:22.04 nvidia-smi
```
Then run the project test:
```bash
cd src/tests
./Test00_verifyDockerGPU.sh
```
If host `nvidia-smi` fails, OpenHealth is not yet the useful diagnostic target.
If the host works but Docker fails, investigate NVIDIA Container Toolkit.
If Docker works but the Flower image does not see CUDA, investigate the client image/runtime rather than governance.
## 32. Model exists but inference fails
Separate model existence from governance admission.
First run the non-governed analytical smoke test:
```bash
cd src/tests
./Test1D_validate_non_governed.sh
```
If direct model evaluation fails, the problem is analytical or artefact-related.
If direct model evaluation succeeds but governed inference fails, move upward into:
```text
selected envelope
ECT status
holder proof
Gatekeeper decision
Hub orchestration
```
This comparison is exactly why the repository retains a non-governed model smoke test.
## 33. Model changed during a governance-only test
Some tests intentionally exercise admission without executing Flower.
`Test3G_mode1a_guest_contribution_admission.sh`, for example, hashes the existing model before and after the contribution-admission checks.
If that hash changes, the test has detected unexpected execution or artefact mutation.
Do not dismiss this as harmless retraining. The point of the test is to isolate admission from execution.
## 34. Hal unexpectedly reaches an internal service
Do not diagnose Mode 1B isolation manually from a single ping or TCP result.
Run:
```bash
cd src/tests
LAN_IP="$HOST_IP" ./Test5A_agent_isolation.sh
```
The test expects:
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
If a federation-internal service becomes reachable directly from Hal, inspect:
```bash
docker inspect hal |
  jq '.[0].NetworkSettings.Networks'

docker inspect fc-hub |
  jq '.[0].NetworkSettings.Networks'
```
Hal should be attached only to `agent-edge`.
The Hub should be attached to `agent-edge` and `fc`.
## 35. Hal can reach a host-published mTLS edge
This is not automatically an isolation failure.
The local architecture distinguishes network routing from federation authority. A host-published verifier or issuer port can potentially be routable from the `agent-edge` context, while mTLS still prevents Hal from using the governed service because Hal does not hold an accepted federation client certificate.
`Test5A_agent_isolation.sh` checks this explicitly.
A result such as:
```text
400 No required SSL certificate was sent
401
403
TLS rejection
```
is consistent with the intended host-edge boundary.
> ⚠️ **Interpretation constraint**
> - `TCP connection succeeded` does not mean `federation authority obtained`.
> - For published governance edges, verify cryptographic usability rather than route existence alone.
## 36. Hal contains unexpected credentials
Inspect Hal's mounts:
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
The expected mounts are limited to Hal's own persistent identity and the read-only external reasoning credential.
Hal should not receive:
```text
human holder-key vault
shared verifier certificate directory
governance evidence private key
verifier vault
```
If those appear, treat the condition as an isolation defect.
## 37. Hal reasoning runtime reports no API key
Local Hal checks:
```text
OPENAI_API_KEY
```
first and then the mounted local development file.
Inspect whether the file is mounted:
```bash
docker inspect hal |
  jq '.[0].Mounts'
```
Check that the file exists inside the container without printing its contents:
```bash
docker exec hal \
  test -s /run/secrets/openai.env &&
  echo "reasoning credential file present"
```
Do not `cat` the credential during troubleshooting.
Do not paste it into logs, tickets, screenshots, or shell history.
## 38. Hal cannot reach the reasoning runtime
Inspect Hal logs:
```bash
docker logs --tail 200 hal
```
Relevant local errors include:
```text
openai_api_key_not_configured
openai_unreachable
openai_http_<status>
openai_response_has_no_text
```
Interpret them separately.
`openai_api_key_not_configured` is secret provisioning.
`openai_unreachable` is network, DNS, TLS, or provider reachability.
`openai_http_401` generally indicates runtime credential rejection.
A provider HTTP error is not a Gatekeeper failure.
The AWS port can use the Bedrock OpenAI-compatible Responses API, but the same diagnostic separation remains valid.
## 39. Reasoning runtime returns invalid JSON
Hal validates the response returned by the reasoning runtime.
If the runtime returns invalid JSON, Hal falls back to:
```text
refuse
```
with a reason indicating that the reasoning runtime returned invalid JSON.
If the runtime selects an action not present in the available action set, Hal also falls back to `refuse`.
These fallbacks are execution safeguards.
They are not Gatekeeper DENY decisions and should not be diagnosed as capability failures.
## 40. Mode 1B contextual test fails
Run:
```bash
cd src/tests
ISSUER_IP="$HOST_IP" \
VERIFIER_IP="$HOST_IP" \
./Test5E_mode1b_contextual_agent.sh "$EID"
```
Classify the failure before changing anything.
If source admission differs from expectation, inspect requester capability and Gatekeeper policy.
If Hal cannot reason, inspect the external reasoning runtime.
If unbind is denied unexpectedly, inspect Hal's bounded capability and requested scope.
If derivative release is denied unexpectedly, inspect the requester's derivative-reader capability.
If the wrong representation is returned despite correct admission state, inspect Hub orchestration and Hal execution.
One user-visible request can involve several independent governed decisions.
## 41. Audrey and Bob produce different results
That is intentional when the requested tissue lies in different source scopes.
The current contextual scenario expects:
```text
Audrey + mucus
    source ALLOW

Audrey + colorectal adenocarcinoma epithelium
    source DENY
    derivative path

Bob + colorectal adenocarcinoma epithelium
    source ALLOW

Bob + mucus
    source DENY
    derivative path
```
Do not "normalise" Audrey and Bob to identical source capability in order to make their outputs consistent. Their asymmetry is the experiment.
## 42. Unbind succeeds but no derivative is returned
A successful Hal `unbind` is not sufficient for release.
The requester must also be admitted for:
```text
consume_derivative
```
Inspect the result for separate:
```text
source admission
Hal action
unbind admission
representation
requester derivative-consumption admission
```
If unbind is ALLOW but release is DENY, investigate requester derivative authority.
Do not make the Hub return the derivative simply because transformation succeeded.
> 🔑 **Takeaway**
> - Transformation and release are separate authority boundaries.
> - A successful tool invocation is not a release credential.
## 43. Evidence does not match the dashboard
The dashboard is an operational presentation layer.
Signed Gatekeeper evidence is the authoritative research evidence for admission decisions.
Inspect the decision directory:
```bash
find \
  src/vfp-governance/verifier/state/events/decisions \
  -maxdepth 1 \
  -type f \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' 2>/dev/null |
  sort
```
Use the corresponding conformance test to verify signatures rather than editing decision files manually.
For the shared substrate:
```bash
cd src/tests
ISSUER_IP="$HOST_IP" \
./Test2E_fcac_conformance.sh "$EID"
```
## 44. A test fails after another test recreated state
The suite is intentionally stateful.
Before assuming regression, determine whether the previous operation:
```text
created a new envelope
selected another envelope
minted or expired an ECT
registered a holder
started another training run
recreated a container
changed a persistent identity
```
The current selected boundary can always be checked with:
```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq .
```
Do not reconstruct state from memory when the application can report it directly.
## 45. A container was recreated and something unrelated broke
This deserves repeating because it was the principal local operational trap.
Ask immediately:
```text
Did an nginx proxy point to that container?
Did the recreated container receive another Docker IP?
Does a dependent proxy still have the previous address cached?
```
Then restart only the relevant nginx container and retest.
A container replacement can therefore create a **routing symptom without an application regression**.
## 46. OpenTofu and running Docker state disagree
Inspect the OpenTofu state:
```bash
cd src/infra/tofu
tofu state list
```
Inspect the plan:
```bash
tofu plan \
  -var="lan_ip=${HOST_IP}"
```
Compare with:
```bash
docker ps -a
```
Do not manually recreate a large subset of containers and then assume OpenTofu still describes the running environment.
Where infrastructure configuration changed, use `tofu apply` to restore convergence.
## 47. Rebuild only the component that changed
For example, after a frontend source change:
```bash
cd src/infra/tofu

tofu apply \
  -var="lan_ip=${HOST_IP}" \
  -replace=docker_image.frontend \
  -replace=docker_container.frontend_even \
  -auto-approve
```
After replacing an upstream service, remember the proxy-resolution issue described earlier.
Avoid rebuilding the entire deployment simply to repair one image.
## 48. Quick mTLS diagnostic set
These commands provide a useful compact trust-edge check.
Verifier public health:
```bash
curl -fsS \
  --resolve "verifier.local:8443:${HOST_IP}" \
  --cacert "$CA" \
  https://verifier.local:8443/health |
  jq .
```
Verifier protected path without client identity:
```bash
curl -sS \
  --resolve "verifier.local:8443:${HOST_IP}" \
  --cacert "$CA" \
  -o /tmp/v.out \
  -w 'HTTP %{http_code}\n' \
  -X POST \
  https://verifier.local:8443/admission/check \
  -H 'content-type: application/json' \
  -d '{}'
cat /tmp/v.out
```
Verifier path with Hub identity:
```bash
curl -sS \
  --resolve "verifier.local:8443:${HOST_IP}" \
  --cacert "$CA" \
  --cert "$HUB_CRT" \
  --key "$HUB_KEY" \
  -o /tmp/v-hub.out \
  -w 'HTTP %{http_code}\n' \
  -X POST \
  https://verifier.local:8443/admission/check \
  -H 'content-type: application/json' \
  -d '{}'
cat /tmp/v-hub.out
```
Hospital A issuer:
```bash
curl -fsS \
  --resolve "issuer-hospitala.local:9443:${HOST_IP}" \
  --cacert "$CA" \
  --cert "$ADMIN_A_CRT" \
  --key "$ADMIN_A_KEY" \
  https://issuer-hospitala.local:9443/members |
  jq .
```
These four probes distinguish basic TLS reachability, protected-edge enforcement, Hub mTLS identity, and issuer mTLS operation.
## 49. Quick application diagnostic set
Direct Hub:
```bash
curl -fsS \
  http://127.0.0.1:8080/administration/boundary |
  jq .
```
Frontend-to-Hub:
```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq .
```
Select the expected envelope:
```bash
curl -fsS \
  -X POST \
  "http://127.0.0.1:8082/api/administration/envelopes/${EID}/select" |
  jq .
```
Inspect holder readiness:
```bash
curl -fsS \
  http://127.0.0.1:8082/api/administration/boundary |
  jq '.holders[] |
      {
        principal,
        enrollment_status,
        ect_status,
        expires_at
      }'
```
Governed inference:
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
    admission,
    executed,
    model_run_id
  }'
```
Together these commands usually identify whether the failure is presentation, orchestration, credential, or admission related.
## 50. What not to fix with `curl -k`
`curl -k` can be useful to inspect a broken TLS endpoint during diagnosis, but it disables server-certificate verification.
It must not become the documented operational path for OpenHealth-CDI.
If a request works only with:
```bash
curl -k
```
while the same request fails with:
```bash
--cacert "$CA"
```
the TLS trust configuration is not healthy.
Repair certificate trust rather than institutionalising `-k`.
## 51. When to run the conformance tests instead of more ad hoc probes
Hand-written `curl` commands are excellent for locating the failing layer.
Once the suspected layer is operational again, use the corresponding executable test to re-establish the invariant.
Examples:
```text
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

Mode 1B Table 7
    Test5D

contextual reasoning
    Test5E
```
Troubleshooting proves that the system is reachable again. Conformance tests prove that it still behaves as intended.
## 52. Troubleshooting order
A practical failure-analysis sequence is:
```text
1. Inspect running containers.
2. Inspect logs before restarting anything.
3. Check direct Hub.
4. Check frontend-to-Hub.
5. If only proxy path fails after recreation, restart the relevant nginx proxy.
6. Confirm the selected governance envelope.
7. Confirm holder registration and ECT readiness.
8. Check verifier public TLS health.
9. Check mTLS identity path.
10. Exercise one known ALLOW and one known DENY.
11. If execution fails after ALLOW, inspect Flower/model/runtime.
12. For Mode 1B, separate Hal isolation, Hal credential, reasoning runtime, unbind, and release.
13. Run the relevant formal conformance test after repair.
```
This order minimises destructive changes and isolates the failure domain quickly.
## 53. Troubleshooting summary
The central operational lesson from the local implementation is that apparently architectural failures often originate in much simpler platform state. The clearest example is nginx retaining an obsolete Docker upstream after an upstream container has been recreated. In that case the application code, governance policy, certificate material, and recreated service can all be correct while the user-facing path still fails.
The reverse is also important. A technically successful connection or computation does not prove correct federation behaviour. Expected DENY decisions, holder-proof failures, mTLS rejection, and Mode 1B network denial are often evidence that the system is behaving correctly.
Effective troubleshooting therefore proceeds by preserving state, isolating layers, comparing direct and proxied paths, checking cryptographic boundaries independently from application admission, and using the executable tests to re-establish the relevant invariant after the immediate operational problem has been repaired.

## 54. Mandatory delivery preflight

Before interpreting a demo, validation, Mode 1B, or AWS-porting failure, run the deterministic delivery preflight from the repository root:

```bash
./src/tests/Test0B_delivery_preflight.sh "$EID" "$HOST_IP"
```

The preflight is deliberately read-only. It does not select an envelope, mint credentials, restart containers, retrain a model, alter policy, or modify governance state.

It checks the operational layers that must be distinguished before troubleshooting:

```text
required containers are running
direct Hub boundary is reachable
the expected envelope is selected
Flower is registered with the Hub
Flower /health reports ready
Flower is bound to the expected envelope
frontend-to-Hub routing is current
verifier TLS health works with the project CA
Hospital A and Hospital B issuer mTLS paths work
Hal has the intended network topology
Hal holder identity and reasoning credential file are present
Gate 5A isolation remains GREEN
```

A GREEN preflight means that the local substrate required for governed Mode 1B execution is ready. It does not call the external reasoning provider and therefore does not prove provider availability or contextual reasoning. `Test5E_mode1b_contextual_agent.sh` remains the executable proof of the composed Mode 1B path.

A RED preflight is a diagnostic result. Do not create a new envelope, delete volumes, broaden capability, or rebuild the full deployment merely to make it GREEN. Repair the first failed layer.

The following distinction is operationally important:

```text
container running
≠ backend registered
≠ backend bound
≠ backend ready
```

During development a recreated Flower server registered successfully with the Hub while PathMNIST was still being downloaded and initialized. The container was running and port 8081 was listening, yet prediction timed out. The readiness check exists to prevent that state from being mistaken for a governance or Mode 1B regression.

### Portability rule

Operational recovery must not depend on prior ChatGPT, Claude, OpenAI-account, Anthropic-account, or developer-conversation context. Those histories can accelerate diagnosis when the original developer is present, but they are not part of the deployable system.

The repository, executable preflight, tests, logs, and this troubleshooting guide must contain enough information for an engineer without that conversational context to identify the failed layer and apply the documented recovery procedure.

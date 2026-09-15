# OpenHealth-CDI Testing and Executable Conformance

## 1. Purpose

OpenHealth-CDI uses executable tests to verify both application behaviour and federation-governance invariants.

A GREEN result can mean more than successful HTTP execution. Depending on the test, it can establish that:

- authority came from the correct issuer;
- a capability was bound to the correct holder and governance envelope;
- a DPoP proof was fresh and non-replayable;
- a denied operation did not execute;
- sponsorship did not become membership or provenance;
- contribution authority did not become model-consumption authority;
- Hal remained outside privileged federation paths;
- source access, transformation, and derivative release were governed as separate relations.

The principal test directory is:

```text
src/tests/
```

The optional admission microbenchmark is under:

```text
src/tests/microbench/
```

This document describes the current v1.1.0 release-validation model. Deployment prerequisites and bootstrap are documented in [DEPLOYMENT.md](DEPLOYMENT.md).

---

## 2. What GREEN means

No single test proves the whole architecture.

For example:

- `Test5A_agent_isolation.sh` verifies Hal's execution boundary and cryptographic custody.
- `Test5C_agent_credential_admission.sh` verifies Hal's holder-bound capability.
- `Test5D_mode1b_table7_conformance.sh` verifies the Mode 1B decision-plane cases.
- `Test5E_mode1b_contextual_agent.sh` verifies contextual source, transformation, and derivative-release behaviour.

The Mode 1B claim depends on these invariants remaining true together.

ALLOW and DENY are both expected outcomes. A negative test is part of the evidence, not an error to remove from a clean demonstration.

---

## 3. Release-validation layers

The delivered tests can be read as the following sequence:

```text
deployment / compute readiness
        |
        v
governance-envelope establishment
        |
        v
A+B training and analytical artefacts
        |
        v
issuer and capability authority
        |
        v
governed model use
        |
        v
holder assurance and sponsorship
        |
        v
Mode 1B isolation and bounded authority
        |
        v
contextual Mode 1B execution
```

Later tests generally assume state established by earlier stages.

---

## 4. Working directory and host endpoint

Most individual shell tests are intended to be run from:

```bash
cd src/tests
```

Several scripts use relative repository paths.

For the portable single-host deployment, use:

```bash
export HOST_IP=127.0.0.1
```

The stable verifier TLS name is:

```text
verifier.local
```

and must already resolve on the host as described in [DEPLOYMENT.md](DEPLOYMENT.md).

Issuer tests commonly use `curl --resolve` internally with the supplied host IP, preserving the issuer TLS names while reaching the selected endpoint.

For scripts that expose explicit variables, use the current host endpoint as required:

```bash
export ISSUER_IP="$HOST_IP"
export VERIFIER_IP="$HOST_IP"
export ISSUER_PROXY_IP="$HOST_IP"
export LAN_IP="$HOST_IP"
```

Do not substitute a remembered laboratory LAN address into a different deployment.

---

## 5. Active governance envelope

Most governance tests require an active envelope:

```bash
export EID=<active-envelope-id>
```

The envelope can be created through the KYO workflow and `Test1A_createEnvelope.sh`.

Reuse the same valid envelope through a coherent regression sequence unless the test purpose explicitly requires a new governance context.

Creating a new envelope is a governance action, not a generic reset operation.

---

## 6. Deployment bootstrap is not test bootstrap

Before release validation, the clean deployment procedure must already have completed:

```text
preflight_bootstrap.sh
tofu apply
bootstrap_members.sh
```

The deployment bootstrap provisions and enrolls the persistent human identities used by the scenarios:

```text
Audrey
Bob
Charlie
```

Tests may mint credentials, select an envelope, create admission evidence, or exercise runtime state. They should not be treated as the normal mechanism for reconstructing a missing deployment.

Hal is different. Its holder identity is created and persisted by the Hal runtime. `Test5C_agent_credential_admission.sh` verifies that identity against the issuer relation and can establish the required runtime registration.

---

## 7. Test0A — compute-backend selection

`Test0A_verifyDockerGPU.sh` is the compute selector for the portable deployment.

Run from the repository root:

```bash
./src/tests/Test0A_verifyDockerGPU.sh
```

The required behaviour is:

```text
no NVIDIA GPU hardware       -> compute_backend = "cpu"
NVIDIA GPU + healthy stack   -> compute_backend = "cuda"
NVIDIA GPU + broken stack    -> FAIL
```

The selected backend is written to:

```text
src/infra/tofu/compute.auto.tfvars
```

The script is intentionally GPU-specific when NVIDIA hardware is present because it must validate the NVIDIA driver, Docker GPU exposure, and CUDA-capable PyTorch image.

It is infrastructure validation, not governance validation.

---

## 8. Test0B — delivery preflight

`Test0B_delivery_preflight.sh` is a read-only readiness check for an already deployed system.

Usage:

```bash
./src/tests/Test0B_delivery_preflight.sh "$EID" "$HOST_IP"
```

It checks:

- required local commands and certificate material;
- required containers;
- selected Hub boundary;
- Flower backend registration;
- Flower readiness and envelope binding;
- frontend-to-Hub path;
- verifier TLS edge;
- Hospital A and B issuer mTLS paths;
- Hal and Hub network topology;
- Hal holder identity and reasoning-credential mount;
- the Mode 1B isolation gate through `Test5A_agent_isolation.sh`.

It does not create a new envelope, retrain the model, mint user credentials, or call the external reasoning provider.

Success ends with:

```text
DELIVERY PREFLIGHT GREEN
```

---

## 9. Test0C — top-level delivery regression

`Test0C_delivery_regression.sh` is the high-value final Mode 1B delivery regression.

Usage from the repository root:

```bash
./src/tests/Test0C_delivery_regression.sh \
  "$EID" \
  "$HOST_IP"
```

It executes:

```text
Test0B
Test5A
Test5C
Test5D
Test5E
```

and propagates the selected host endpoint to the tests that require it.

`Test5D` output is also captured in:

```text
JMIR_paper/table7/Test5D_mode1b_conformance.txt
```

A successful run ends with:

```text
DELIVERY REGRESSION GREEN

ALL DELIVERY GATES GREEN
```

This regression is deliberately targeted. It proves the delivered Mode 1B evidence chain against an already available analytical model. It does not retrain A+B.

---

## 10. Deterministic PathMNIST checks

Two Python tests verify frozen analytical assumptions without running the distributed stack.

From `src/tests`:

```bash
PYTHONPATH=.. python3 test_pathmnist_partition.py
PYTHONPATH=.. python3 test_pathmnist_metrics.py
```

They verify the deterministic partition and metric-grouping assumptions used by the PathMNIST experiment.

These are analytical tests, not federation-governance tests.

---

## 11. Test1A — governance-envelope establishment

`Test1A_createEnvelope.sh` exercises the A+B KYO envelope ceremony.

Run:

```bash
./Test1A_createEnvelope.sh
```

The test is interactive. Hospital A and Hospital B verification codes must be obtained through the authenticated `/verify-start` process.

Success reports:

```text
Envelope created: <envelope-id>
```

Record it:

```bash
export EID=<envelope-id>
```

The invariant is the two-party governed establishment of the collaboration boundary, not merely production of an identifier.

---

## 12. Test1B and Test1C — A+B training and artefacts

`Test1B_postEnvelope.sh` starts a new A+B training lifecycle under the selected envelope:

```bash
./Test1B_postEnvelope.sh "$EID"
```

It verifies the START lifecycle, waits for a new correlated Flower run, and checks the run manifest.

`Test1C_verifyABRounds.sh` verifies the completed analytical artefacts:

```bash
./Test1C_verifyABRounds.sh
```

or:

```bash
./Test1C_verifyABRounds.sh local-pathmnist-ab-001 10
```

For v1.1.0, Test1C is compute-backend aware. It reads the backend selected in:

```text
src/infra/tofu/compute.auto.tfvars
```

and requires Hospital A and B to report the corresponding runtime.

Therefore:

```text
CPU deployment   -> CPU runtime required
CUDA deployment  -> CUDA runtime required
```

It no longer treats CUDA as an A+B conformance invariant.

It also verifies:

- model artefact;
- metrics;
- participants;
- confusion matrices;
- class metrics;
- final model metadata;
- round-zero baseline plus the expected trained rounds;
- Flower completion state.

---

## 13. Test1D and Test1E — analytical smoke tests

`Test1D_validate_non_governed.sh` loads the model directly:

```bash
./Test1D_validate_non_governed.sh
```

This proves model inference functionality without federation admission. It must not be cited as governance evidence.

`Test1E_predict_image.sh` exercises the backend image-prediction path:

```bash
./Test1E_predict_image.sh "$EID"
```

It validates the backend prediction contract. Governed requester admission is tested separately.

---

## 14. Test2 family — issuer, capability, and signed evidence

The Test2 family separates credential construction, issuer authority, holder registration, and Gatekeeper evidence.

| Test | Primary invariant |
| --- | --- |
| `Test2A_run_probe_eddsa_nginx.sh` | direct mint, EdDSA DPoP, Gatekeeper admission |
| `Test2B_mint_ect.sh` | ECT mint contract and scope |
| `Test2C_issuer_mint.sh` | organisation issuer owns entitlement resolution |
| `Test2D_issuer_owned_entitlements.sh` | actor metadata cannot become an authorisation source |
| `Test2E_fcac_conformance.sh` | canonical envelope-policy relation and signed ALLOW/DENY evidence |
| `Test2F_issuer_registration_boundary.sh` | member registry protected by organisation authority |

Typical execution:

```bash
./Test2A_run_probe_eddsa_nginx.sh "$EID"
./Test2B_mint_ect.sh "$EID"

ISSUER_IP="$HOST_IP" ./Test2C_issuer_mint.sh "$EID"
ISSUER_IP="$HOST_IP" ./Test2D_issuer_owned_entitlements.sh "$EID"
ISSUER_IP="$HOST_IP" ./Test2E_fcac_conformance.sh "$EID"
ISSUER_IP="$HOST_IP" ./Test2F_issuer_registration_boundary.sh
```

The central authority invariant is that the caller may request issuance but cannot select its own privilege.

---

## 15. Test3 family — governed execution and Mode 1A

`Test3A_run_pathmnist_e2e.sh` connects policy, credential, admission, and visible model execution:

```bash
ISSUER_PROXY_IP="$HOST_IP" \
  ./Test3A_run_pathmnist_e2e.sh "$EID"
```

`Test3E_dashboard_policy_scope.sh` verifies that Hub and frontend code do not duplicate policy-owned tissue authorisation:

```bash
./Test3E_dashboard_policy_scope.sh "$EID"
```

For every DENY it requires the protected operation not to execute.

`Test3F_mode1a_guest_admission.sh` verifies Charlie's guest-contributor credential relation:

```bash
ISSUER_IP="$HOST_IP" \
  ./Test3F_mode1a_guest_admission.sh "$EID"
```

In the v1.1.0 deployment path, Charlie should already have been provisioned and enrolled by `bootstrap_members.sh`. Any compatibility logic in the test for absent historical state is not a substitute for deployment bootstrap.

`Test3G_mode1a_guest_contribution_admission.sh` verifies the contribution aperture:

```bash
./Test3G_mode1a_guest_contribution_admission.sh "$EID"
```

The key Mode 1A invariant is:

```text
contribution authority != model-consumption authority
```

An admitted Charlie contribution does not grant model-query authority.

---

## 16. Test4 family — holder assurance and sponsorship

`Test4A_dpop_replay_protection.sh` verifies that the exact same DPoP proof cannot be reused:

```bash
./Test4A_dpop_replay_protection.sh "$EID"
```

`Test4B_dpop_iat_freshness.sh` verifies stale, future, and current proof handling:

```bash
./Test4B_dpop_iat_freshness.sh "$EID"
```

`Test4C_sponsorship_regression.sh` verifies explicit sponsorship while preserving issuer, provenance, membership, and ordinary unsponsored-holder semantics:

```bash
ISSUER_IP="$HOST_IP" \
  ./Test4C_sponsorship_regression.sh "$EID"
```

It also reruns the principal Mode 1A governed paths.

The invariant is:

```text
sponsorship is an explicit relation
sponsorship is not provenance
sponsorship is not membership
sponsorship is not delegation
```

---

## 17. Test5A — Hal isolation

`Test5A_agent_isolation.sh` verifies the local execution boundary around Hal.

Run:

```bash
LAN_IP="$HOST_IP" \
  ./Test5A_agent_isolation.sh
```

It verifies:

- Hal is attached only to `agent-edge`;
- the Hub joins `agent-edge` and `fc`;
- Hal can reach the Hub;
- Hal does not have the ordinary federation-internal service path;
- host-published governed edges remain unusable without an accepted federation client identity;
- Hal owns its own holder key;
- Hal does not contain federation evidence-signing material, verifier vault material, or shared federation credentials.

The important claim is not absolute packet impossibility. The claim is that admission remains load-bearing because Hal has no alternate privileged execution path.

---

## 18. Test5C — Hal holder-bound capability

`Test5C_agent_credential_admission.sh` verifies Hal's actual runtime identity against the issuer and capability relation.

Run:

```bash
ISSUER_IP="$HOST_IP" \
VERIFIER_IP="$HOST_IP" \
  ./Test5C_agent_credential_admission.sh "$EID"
```

The resulting ECT must bind the current Hal JKT and grant only the bounded-agent capability required by Mode 1B.

The expected admission probes include:

```text
bounded_inference  -> ALLOW
query_model        -> DENY
submit_update      -> DENY
```

Useful authority inside the admitted capability and denial outside it are both required.

---

## 19. Test5D — Table 7 decision plane

`Test5D_mode1b_table7_conformance.sh` is the executable five-case Mode 1B decision-plane experiment.

Run:

```bash
ISSUER_IP="$HOST_IP" \
VERIFIER_IP="$HOST_IP" \
  ./Test5D_mode1b_table7_conformance.sh "$EID"
```

Expected decision sequence:

```text
DENY / ALLOW / ALLOW / ALLOW / DENY
```

The five cases are:

1. requester attempts unrestricted source access;
2. Hal bounded inference;
3. Hal policy-authorised Unbind;
4. requester consumes the governed derivative;
5. Hal attempts a privileged governance operation.

The test verifies signed decision evidence rather than relying only on HTTP results.

Mixed ALLOW and DENY results are the intended proof of bounded authority.

---

## 20. Test5E — contextual Mode 1B execution

`Test5E_mode1b_contextual_agent.sh` exercises one Hal identity across different requester-resource relations.

Run:

```bash
ISSUER_IP="$HOST_IP" \
VERIFIER_IP="$HOST_IP" \
  ./Test5E_mode1b_contextual_agent.sh "$EID"
```

The contextual matrix is:

| Requester | Tissue | Source | Hal action | Unbind | Release | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Audrey | `mucus` | ALLOW | `no_transform` | not required | not required | source |
| Audrey | `colorectal_adenocarcinoma_epithelium` | DENY | `blur_image` | ALLOW | ALLOW | derivative |
| Bob | `colorectal_adenocarcinoma_epithelium` | ALLOW | `no_transform` | not required | not required | source |
| Bob | `mucus` | DENY | `blur_image` | ALLOW | ALLOW | derivative |

The external reasoning runtime may choose the permitted action, but it cannot enlarge Hal's admitted authority.

A reasoning-provider failure is a runtime dependency failure unless the governance path itself behaves incorrectly.

---

## 21. Test5D and Test5E answer different questions

Test5D asks:

```text
Does the governance model enforce the Mode 1B capability and decision relations?
```

Test5E asks:

```text
Can a stochastic reasoning runtime participate inside those relations while requester-resource context remains authoritative?
```

A successful LLM-generated action cannot compensate for a failed governance invariant.

Conversely, a reasoning-provider outage does not invalidate a separately GREEN Test5D decision plane.

---

## 22. Full clean-deployment validation

For a release containing executable changes, the strongest local validation starts from the clean deployment procedure in [DEPLOYMENT.md](DEPLOYMENT.md), then runs the relevant analytical and governance layers.

After bootstrap, `tofu apply`, and `bootstrap_members.sh`:

```bash
cd src/tests

export HOST_IP=127.0.0.1
export ISSUER_IP="$HOST_IP"
export VERIFIER_IP="$HOST_IP"
export ISSUER_PROXY_IP="$HOST_IP"
export LAN_IP="$HOST_IP"
```

Run deterministic checks:

```bash
PYTHONPATH=.. python3 test_pathmnist_partition.py
PYTHONPATH=.. python3 test_pathmnist_metrics.py
```

Create an envelope:

```bash
./Test1A_createEnvelope.sh
export EID=<created-envelope-id>
```

Run A+B:

```bash
./Test1B_postEnvelope.sh "$EID"
./Test1C_verifyABRounds.sh
./Test1D_validate_non_governed.sh
./Test1E_predict_image.sh "$EID"
```

Then execute the relevant Test2, Test3, and Test4 families described above.

Finish with the delivery regression from the repository root:

```bash
cd ../..

./src/tests/Test0C_delivery_regression.sh \
  "$EID" \
  "$HOST_IP"
```

The final acceptance marker is:

```text
ALL DELIVERY GATES GREEN
```

---

## 23. Targeted regression after an already proven training run

Retraining is not required after every change.

When the A+B model and analytical path are already established and the change affects portability, deployment, governance, agent execution, or documentation, use the tests relevant to the changed invariant.

For the v1.1.0 portability work, the final targeted evidence includes:

```text
Test1C  selected CPU/CUDA runtime and A+B artefacts
Test0C  high-value Mode 1B delivery regression
```

This is why the portable CPU release path can reuse an already validated A+B model after the rebuilt Flower runtime has been verified, provided no training semantics changed.

---

## 24. What to rerun after common changes

| Changed area | Minimum relevant regression |
| --- | --- |
| Flower client runtime or compute selection | Test0A, Test1C |
| training lifecycle or Flower backend | Test1B, Test1C, Test3A |
| issuer entitlements or minting | Test2C, Test2D, Test2E, Test2F |
| DPoP or holder binding | Test4A, Test4B, Test5C |
| sponsorship or Mode 1A | Test3F, Test3G, Test4C |
| Hub or frontend policy path | Test3E, Test4C, Test5E |
| Docker/network/mTLS boundary | Test0B, Test5A, Test2F, Test2E, Test5C |
| Mode 1B governance logic | Test5A, Test5C, Test5D, Test5E |
| documentation only | no executable rerun unless documentation reveals an unresolved implementation discrepancy |

When policy or constitutional participants change, establish a fresh envelope under the new governance state rather than reusing one created under incompatible conditions.

---

## 25. Failure classification

Classify the failed layer before changing the system.

Typical classes are:

- **deployment failure** — missing container, unresolved name, missing certificate, unreachable proxy;
- **compute failure** — selected CPU/CUDA runtime cannot start or does not match deployment selection;
- **issuer failure** — wrong entitlement, caller-selected profile, wrong issuer, wrong registration;
- **holder-assurance failure** — DPoP binding, replay, freshness, or key mismatch;
- **Gatekeeper/policy failure** — unexpected ALLOW or DENY for a correctly formed request;
- **execution failure** — admission succeeds but the protected operation fails;
- **architecture failure** — an operation executes after DENY or a participant retains a bypass path;
- **reasoning-runtime failure** — Test5E cannot reach or use the configured external LLM while governance remains correct.

Do not respond to an unclassified failure by regenerating envelopes, certificates, identities, or the complete deployment.

---

## 26. Decision evidence

Admission decision records are stored beneath:

```text
src/vfp-governance/verifier/state/events/decisions/
```

A decision record is evidence of one concrete attempted relation.

A Mode 1B derivative workflow can therefore produce multiple valid records:

```text
source request                 -> DENY
Hal Unbind                     -> ALLOW
requester derivative release   -> ALLOW
```

These records are complementary, not contradictory.

---

## 27. Generated evidence files

Some tests intentionally capture evidence into repository paths. In particular, `Test0C_delivery_regression.sh` captures Test5D output into:

```text
JMIR_paper/table7/Test5D_mode1b_conformance.txt
```

This means a successful regression can modify a tracked evidence file even when executable source is unchanged.

Before committing portability or documentation changes, inspect the working tree and restore generated evidence unless the release intentionally updates the evidence artefact.

---

## 28. Model-quality interpretation

PathMNIST provides a real analytical workload for the federation experiment.

Unless a test explicitly defines a numerical acceptance threshold, accuracy, per-class recall, and other model-quality results are diagnostic evidence rather than governance pass/fail criteria.

Training variation must not be misclassified as a governance failure.

---

## 29. Admission microbenchmark

The optional benchmark is:

```text
src/tests/microbench/Bench_admission_pathmnist.sh
```

Example:

```bash
cd src/tests/microbench

BENCH_CASE=allow NITER=1000 \
  ./Bench_admission_pathmnist.sh "$EID"
```

Supported cases include ALLOW, scope denial, holder-binding denial, and reserved-tissue denial.

The benchmark measures the Gatekeeper admission path. It does not measure end-to-end user latency, model inference, ECT issuance, DPoP construction, external reasoning, or derivative transformation.

---

## 30. Local tests and AWS acceptance

Some tests encode their invariant through Docker-specific mechanisms.

`Test5A_agent_isolation.sh` is the clearest example. Locally it inspects Docker network membership and connectivity. In AWS the same invariant must be expressed through the deployed VPC, routing, security groups, task or instance interfaces, service discovery, and mTLS edges.

The rule is:

> When the implementation mechanism changes, preserve the invariant and re-test the invariant against the new mechanism.

See [AWS-PORTING.md](AWS-PORTING.md).

---

## 31. Current top-level test catalogue

| Test | Primary concern | Active envelope |
| --- | --- | --- |
| `Test0A_verifyDockerGPU.sh` | CPU/CUDA compute selection and GPU validation | no |
| `Test0B_delivery_preflight.sh` | deployed delivery readiness | yes |
| `Test0C_delivery_regression.sh` | final Mode 1B delivery chain | yes |
| `Test1A_createEnvelope.sh` | A+B KYO envelope ceremony | creates one |
| `Test1B_postEnvelope.sh` | START, A+B training, run evidence | yes |
| `Test1C_verifyABRounds.sh` | backend-aware A+B analytical artefacts | no explicit EID |
| `Test1D_validate_non_governed.sh` | direct model smoke test | no |
| `Test1E_predict_image.sh` | backend image prediction | yes |
| `Test2A_run_probe_eddsa_nginx.sh` | direct DPoP and admission probe | yes |
| `Test2B_mint_ect.sh` | ECT mint contract | yes |
| `Test2C_issuer_mint.sh` | issuer-owned minting | yes |
| `Test2D_issuer_owned_entitlements.sh` | issuer authority separation | yes |
| `Test2E_fcac_conformance.sh` | envelope-policy and signed evidence | yes |
| `Test2F_issuer_registration_boundary.sh` | issuer registry authority | no |
| `Test3A_run_pathmnist_e2e.sh` | governed model execution | yes |
| `Test3E_dashboard_policy_scope.sh` | policy-owned Hub/frontend path | yes |
| `Test3F_mode1a_guest_admission.sh` | Charlie guest credential | yes |
| `Test3G_mode1a_guest_contribution_admission.sh` | contribution boundary | yes |
| `Test4A_dpop_replay_protection.sh` | DPoP replay resistance | yes |
| `Test4B_dpop_iat_freshness.sh` | DPoP temporal validity | yes |
| `Test4C_sponsorship_regression.sh` | sponsorship and Mode 1A regression | yes |
| `Test5A_agent_isolation.sh` | Hal isolation and custody | no |
| `Test5C_agent_credential_admission.sh` | Hal holder-bound capability | yes |
| `Test5D_mode1b_table7_conformance.sh` | Mode 1B decision-plane conformance | yes |
| `Test5E_mode1b_contextual_agent.sh` | contextual Mode 1B execution | yes |
| `test_pathmnist_partition.py` | deterministic data partition | no |
| `test_pathmnist_metrics.py` | deterministic metric groups | no |

Historical filenames containing `fcac` are retained for traceability. Their names do not redefine the scope of the current OpenHealth-CDI architecture.

---

## 32. Release acceptance

For a release with executable changes, rerun the tests that establish every affected invariant.

For a documentation-only change over an already verified executable baseline, a complete analytical retraining is not inherently required. The release record must identify the executable state against which the documentation was reconciled.

A release must not be declared conformant while a known architecture-relevant test is failing or while a stronger previous assertion has been silently replaced by a weaker one.

For the portable v1.1.0 reference deployment, the final high-level acceptance conditions are:

```text
bootstrap preflight PASS
OpenTofu deployment PASS
member bootstrap PASS
Test1C GREEN on selected CPU/CUDA backend
Test0C ALL DELIVERY GATES GREEN
```

Release mechanics are documented in [RELEASE.md](RELEASE.md).

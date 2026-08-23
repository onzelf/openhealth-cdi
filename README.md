# OpenHealth CDI

OpenHealth CDI is a research proof of concept for governed admission in
cross-organizational federated health-data collaboration.

The implementation separates execution from authority. Human participants and
the non-human participant Hal act through holder-bound credentials, while a
deterministic governance plane evaluates the admitted relation before an
operation can reach the data or model plane.

The repository implements the three scenarios used in the accompanying paper.

| Scenario | Demonstrated relation | Status |
| --- | --- | --- |
| Mode A+B | Founding Hospitals A and B train and query under an active sovereignty envelope | Complete |
| Mode 1A | Sponsored Hospital C contributes to training without acquiring ordinary member or model-consumption authority | Complete |
| Mode 1B | Hal participates as a bounded non-human actor with independently governed inference and rebind authority | Complete for the paper governance experiment |

<p align="center">
<img src="doc/slide_0.png" width="75%">
</p>

## What is being demonstrated

The proof of concept combines the following mechanisms.

- sovereignty-envelope creation through quorum approval
- issuer-owned entitlements compiled into envelope-bound capability tokens
- holder binding through DPoP
- capability and scope evaluation at the Gatekeeper
- explicit sponsorship relations
- signed ALLOW and DENY decision evidence
- separation of contribution authority from model-consumption authority
- isolation of the Mode 1B agent from privileged federation paths

Mode 1B deliberately separates the governed participant from any future LLM
reasoning runtime. Hal is the governance-side non-human participant. Its
identity, sponsors, capabilities and envelope binding remain deterministic
even if a stochastic reasoning engine is later attached to it.

The security invariant is therefore independent of the reasoning mechanism.
Execution may vary, but execution cannot enlarge admitted authority.

## Repository layout

```text
src/
  infra/tofu/                  OpenTofu deployment
  tests/                       executable conformance and smoke tests
  tools/                       certificate, holder and DPoP utilities
  vfp-core/
    agents/hal/                isolated Mode 1B participant
    backend/                   Flower and PathMNIST execution plane
    frontend/                  demonstration dashboard
    hub/                       coordination layer
    issuers/                   issuer services and entitlements
  vfp-governance/
    gatekeeper/                admission decision service
    verifier/                  policy, constitution, evidence and vault

JMIR_paper/
  table7/                      Mode 1B Table 7 conformance evidence
  table8/                      admission microbenchmark evidence
```

## Bootstrap

### Prerequisites

The reference environment uses:

- Docker
- OpenTofu
- Python 3
- `jq`
- `curl`
- OpenSSL
- an NVIDIA GPU and NVIDIA Container Toolkit for PathMNIST training

The OpenTofu configuration exposes the mTLS edge on the host LAN address.
`verifier.local` must resolve to the same host when reproducing the quorum
ceremony.

### Generate the local PKI

From the repository root:

```bash
./src/tools/make_certs.sh true
```

The optional `true` argument also creates the Android-compatible administrator
PKCS#12 bundles used by the two-party KYO demonstration.

### Provision the complete environment

```bash
cd src/infra/tofu

tofu init
tofu apply -auto-approve -var='lan_ip=<HOST_LAN_IP>'
```

The dashboard is exposed locally at:

```text
http://127.0.0.1:8082
```

### Create and activate a sovereignty envelope

```bash
cd ../../tests

./Test1A_createEnvelope.sh
```

`Test1A_createEnvelope.sh` performs the two-party approval ceremony and prints
the resulting envelope identifier. Export it for the remaining tests.

```bash
export ENVELOPE_ID=<ENVELOPE_ID_PRINTED_BY_TEST1A>
```

The post-envelope smoke test binds the execution plane and produces the
baseline A+B model.

```bash
./Test1B_postEnvelope.sh "$ENVELOPE_ID"
```

## Mode A+B

Mode A+B is the governed founding collaboration. Hospitals A and B are members
of the active envelope, train the baseline PathMNIST model and consume model
predictions under issuer-owned capabilities.

The principal end-to-end smoke test is:

```bash
./Test3A_run_pathmnist_e2e.sh "$ENVELOPE_ID"
```

This exercises the full path from policy and issuer enrollment through ECT and
DPoP admission to real model execution. It also checks that model consumption
remains capability- and tissue-scoped.

## Mode 1A

Mode 1A introduces Hospital C without turning it into a founding member.
Charlie is a sponsored guest contributor. Contribution authority is admitted
independently from model-consumption authority.

The relevant governance smoke tests are:

```bash
./Test3F_mode1a_guest_admission.sh "$ENVELOPE_ID"
./Test3G_mode1a_guest_contribution_admission.sh "$ENVELOPE_ID"
```

These tests verify the sponsored guest relation, holder-bound credential,
training-only capability, permitted contribution scope, reserved-tissue DENY,
and absence of model-query authority.

The dashboard also exposes the Mode 1A A+B+C training scenario.

## Mode 1B

Mode 1B introduces Hal as a non-human participant sponsored by Hospitals A and
B. Hal has its own Ed25519 holder identity and runs on an isolated
`agent-edge` network. It has no direct route to the verifier, issuers,
holder-signer, Redis or Flower services.

Its admitted capabilities are intentionally narrow.

- bounded inference on the declared cancer-related scope
- policy-authorized rebind on that same scope
- no ordinary member participation capability
- no training capability
- no unrestricted model-query capability
- no privileged governance path

The isolation and credential-bound admission tests are:

```bash
./Test5A_agent_isolation.sh
./Test5C_agent_credential_admission.sh "$ENVELOPE_ID"
```

The paper-level Mode 1B conformance test is:

```bash
./Test5D_mode1b_table7_conformance.sh "$ENVELOPE_ID"
```

It reproduces the five decisions reported in Table 7.

| Table 7 case | Expected decision |
| --- | --- |
| Audrey requests unrestricted cancer-related source output | DENY |
| Hal performs bounded inference | ALLOW |
| Hal invokes policy-authorized rebind | ALLOW |
| Audrey consumes the corresponding derivative representation | ALLOW |
| Hal attempts a privileged governance path | DENY |

The expected summary is:

```text
TABLE 7 RESULT
5 / 5 GREEN
```

The rebind test concerns governance of the transformation relation. The
concrete image transformation is a data-plane operation and is not required
for the admission result. A future LLM-backed Hal may select among permitted
image manipulations or statistical queries without changing the governance
model.

## Cross-cutting regression checks

Two compact regression tests exercise the shared governance substrate across
the scenarios.

```bash
./Test2E_fcac_conformance.sh "$ENVELOPE_ID"
./Test4C_sponsorship_regression.sh "$ENVELOPE_ID"
```

## Publication evidence

Evidence generated for the paper is retained under:

```text
JMIR_paper/table7/
JMIR_paper/table8/
```

Table 7 contains the Mode 1B conformance execution evidence. Table 8 contains
the admission latency measurements.

The signed admission records generated during execution are stored by the
verifier under its decision-evidence state and are independently verifiable
against the pinned evidence public key.

## Scope

This repository is a proof of concept, not a production healthcare platform.
The purpose is to make the governance relations executable and inspectable.
The current Mode 1B dashboard exposes bounded inference, while the complete
Table 7 governance experiment is exercised through the conformance test.

The next engineering layer can attach an LLM reasoning runtime and additional
data-plane tools to Hal. That extension does not require the LLM to become an
authority source. The governance plane remains the authoritative representation
of what the participant may do.

## License

OpenHealth CDI is released under the GNU Affero General Public License v3.0.
See `LICENSE`.

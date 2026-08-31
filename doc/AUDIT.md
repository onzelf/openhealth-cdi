# AUDIT.md — Independent Review Record

**Repository:** `onzelf/openhealth-cdi`, branch `delivery`
**Audit anchor commits:** `1c5a108` (initial audit) → `2b88a24` (F-1 resolution) → `5430bd3` (F-3 resolution) → `17fcfd2` (R-1 architectural resolution) → `1d395d7` (final tested evidence head)
**Audit dates:** 30–31 August 2026
**Status:** CLOSED at `1d395d7`. No open findings. Residual maintenance notes are recorded in §8.

## 1. Purpose of this document

This repository makes falsifiable claims about its own governance architecture. This document records what happened when those claims were independently attacked: the audit criterion, the scope, the findings, the fixes, and the limits of what the review establishes. It exists so that the artifact is self-disclosing — a reader who discovers that the review chain included AI systems discovers it here, in the maintainer's own record, together with the responsibility statement in §10.

The audit history is part of the evidence, not an embarrassment appended to it. Two of the findings recorded below were defects in claims the repository states about itself, one of them the central Mode 1B claim, found after earlier reviews had passed it. This record also documents one instance of the auditor being wrong and being corrected by the maintainer (§7). A review process that never finds anything, and never errs, establishes nothing.

## 2. Audit criterion

Findings were graded by one question: **does the code contradict something the artifact claims about itself?** This is a research reference implementation, not a production system. Attack surface on a single-host demonstrator was out of scope. A property documented as a trust-boundary assumption is an assumption, not a defect; a property the documentation asserts but the implementation or tests cannot support is a defect regardless of exploitability.

The boundary statements in [ARCHITECTURE.md](ARCHITECTURE.md) had been written with input from the same models that performed earlier reviews and had not had an independent read. The audit therefore treated the documentation itself as a subject, not as ground truth. The same applied to the statelessness claim in the JMIR manuscript, audited in the second round (§6).

## 3. Review chain

Two prior model-based reviews were scoped to the governance plane's decision logic (maintainer-reported). The first round of the present audit was deliberately scoped to what those reviews had not covered: deployment topology (`src/infra/tofu/main.tf`), the nginx mTLS edges, the signer and issuers, the Hub's Mode 1B composition path, and the conformance suite. A second round audited one claim from the JMIR manuscript concerning stateless admission.

Each round was repeated against the commits resolving the previous round's findings, until a round produced none.

## 4. Claims audited and verdicts

| # | Claim | At `1c5a108` | At `5430bd3` | At `1d395d7` |
|---|-------|--------------|--------------|--------------|
| 1 | Mode 1B releases a derivative only when the producer's `unbind` and the recipient's `consume_derivative` are separately admitted | HOLDS | HOLDS | HOLDS |
| 2 | `W_created = W_named_in_signed_decision = W_released` — the content-addressed governed value is enforced end to end, not merely reported | **CONTRADICTED (F-1)** | HOLDS | HOLDS |
| 3 | Hal is isolated from federation-internal services; host-published mTLS edges are routable but unusable without an accepted client identity | HOLDS | HOLDS | HOLDS |
| 4 | Capability assignment is issuer-owned; the requester cannot select its own profile, sponsors, or actor type | HOLDS | HOLDS | HOLDS |
| 5 | Decision evidence is authentic per record; completeness is a documented limitation, not a claim | HOLDS | HOLDS | HOLDS |
| 6 | Admission is stateless with respect to governance and authorization state and fails closed on invalid presented authority | NOT AUDITED | **CONTRADICTED (R-1); wording required scoping (R-2)** | HOLDS |

Supporting observations for the claims that held throughout: the composed Mode 1B path in `hub.py` contains no return that carries a derivative without both admissions; `Test5A` verifies both halves of the reachability-versus-authority statement at exactly the edges that are host-published; the issuer's `MintReq` forbids extra fields and resolves profiles, sponsors, and actor type from issuer-owned entitlement configuration, with `org_iss` derived from the mTLS client DN rather than the request body; decision records are signed over canonical JCS bytes with a pinned Ed25519 key and are verifiable by the standalone `verify_fcac_evidence.py` through independent tooling (openssl).

## 5. Round one findings

### F-1 — Exact-W identity was reported, not enforced (High) — RESOLVED at `2b88a24`

**Location (at `1c5a108`):** `src/vfp-governance/gatekeeper/app.py` (consume_derivative handling, format check only); `src/vfp-core/hub/hub.py` (`mode1b_agent_request`, W construction and release).

The Gatekeeper validated only the *format* of `governed_value_id` (`sha256:` + 64 hex). It never received W, never recomputed the identity, and would sign a decision naming whatever identifier the Hub supplied. The equality `W_created = W_named = W_released` was true only inside a single trusted process; the signed decision could not, on its own, establish it. `Test5E` did not detect this because its recomputation compared three quantities that all originated from the same Hub response — it verified the Hub's internal consistency, not an independently checkable binding. The defect survived earlier reviews for the same reason: the test checked the wrong side of the trust boundary, and every reviewer trusted the test.

**Resolution (`2b88a24`, maintainer's design, superseding the auditor's proposed manifest patch):** the Hub presents the full candidate W with the `consume_derivative` admission request. The Gatekeeper, after — and only after — the capability match, cross-checks W against the admitted relation (resource, requested tissue, derivative representation), recomputes the content address over canonical W, decodes the derivative image bytes and re-verifies them against `derivative_sha256`, and denies with an attributable reason on any mismatch. A successful signed decision embeds the exact verified W together with `verified_governed_value_id`; candidate values are deliberately not persisted in DENY evidence. The Hub additionally re-verifies the content address and byte digest immediately before release, closing the admission-to-release window. The documented chain is now `W_created = W_verified_by_Gatekeeper = W_evidenced = W_released` (`GOVERNANCE_COMPOSITION.md` §8).

### F-2 — Hub as sole, undeclared binder of W (Low–Medium, declared-adequacy) — DISSOLVED by F-1's resolution

At `1c5a108` the Hub was the only party that received Hal's derivative bytes (trusting Hal's reported digest without re-hashing) and computed `value_id`, and this trust concentration was not stated as an assumption. At `2b88a24` the Gatekeeper independently verifies both, the Hub re-hashes Hal's bytes locally, and the documentation states the mechanism; the finding no longer applies.

### F-3 — Mode 1A guest-contribution endpoint broken by the exact-W change (Medium) — RESOLVED at *5430bd3*

**Location (at `1c5a108` and `2b88a24`):** `src/vfp-governance/gatekeeper/app.py`, `GuestContributionProbe`.

Commit `1c5a108` added `governed_value_id` to the shared admission core (`req_tuple`, `emit_decision_record`), which serves two endpoints. `/admission/check` parses into the Pydantic `ProbeReq`, where new optional fields default automatically; `/admission/guest-contribution` uses the hand-maintained mirror class `GuestContributionProbe`, which was not updated. Every call to the guest endpoint therefore raised `AttributeError` → HTTP 500 on both the ALLOW branch (tuple construction) and the DENY branch (evidence emission): the Mode 1A aperture could return neither a decision nor signed evidence. The regression went undetected because the introducing commits were validated only through the Mode 1B endpoint; `Test3G` (and `Test4C`, which executes it) are the detectors and were not rerun.

**Resolution (`5430bd3`):** `governed_value_id = None` and `governed_value = None` added to the mirror class. The structural remedy — constructing `ProbeReq` directly in the guest endpoint so the mirror class ceases to exist — is recorded as maintenance (§8).

## 6. Round two findings — stateless admission

### R-1 — Admission reconstructed authority from mutable governance state (High) — RESOLVED at *17fcfd2*

**Location (at `5430bd3`):** `src/vfp-governance/gatekeeper/app.py`, `_probe_impl`.

Admission called `load_active_envelope(body.envelope_id)` on every request and then re-derived setup-time facts from the retrieved artifact: envelope state and expiry, ECT-to-envelope policy binding, the ECT lifetime bound, and sponsorship validity against envelope participants. An ALLOW therefore depended not only on the presented holder-bound authority and locally compiled governance constraints but also on mutable server-side governance state. This contradicted the FLICS/JMIR phase separation in which governance establishment and capability issuance resolve authority before runtime admission. It also moved the implementation toward the conventional IAM pattern of reconstructing current authority from online state rather than verifying portable authority already established across independently governed domains.

The auditor proposed content-binding the envelope (`envelope_hash` in the ECT, recomputed at admission). **The maintainer rejected that repair** on the grounds that it preserves and hardens a lookup the intended FLICS/JMIR architecture does not perform, and specified the correct repair instead: restore the phase separation.


**Resolution (`17fcfd2`, maintainer's design; completed by the subsequent documentation and conformance commits):** the envelope lookup and sponsorship re-evaluation were removed from `_probe_impl`; the envelope-mediated policy check was replaced by a direct comparison of the ECT policy hash against the locally compiled policy hash (`policy_hash_mismatch`); `envelope_id` became an opaque relation identifier whose consistency is verified across ECT, holder proof, and request. All removed obligations were verified present at issuance: `load_active_envelope` validates signature, ACTIVE state, expiry, and policy chaining; the ECT lifetime is constructively bounded by `exp = min(requested_exp, envelope_exp)`; sponsorship is validated; capability profiles are compiled; and the compiled policy hash is stamped into the signed ECT. `ARCHITECTURE.md` §12 and §12.1 state the resulting architecture and its distinction from IAM.

A consequence of the direct policy-hash binding is that, once the Gatekeeper is running under a new compiled policy hash, ECTs minted under the previous hash fail admission with `policy_hash_mismatch`. This provides global policy-version invalidation; it should not be confused with fine-grained credential revocation.

### R-2 — "Stateless" required explicit scoping (wording, not code) — RESOLVED

Anti-replay requires bounded mutable runtime state (`SET NX EX` over the DPoP `jti`). The unqualified term "stateless" was therefore potentially ambiguous. `ARCHITECTURE.md` §12.1 now states the precise claim: admission is stateless with respect to governance and authorization state. Mutable runtime state is confined to anti-replay protection and evidence persistence; replay-store failure is fail-closed, and replay state cannot supply or enlarge authority.

### Regression evidence for R-1

`Test2E` was extended beyond the test the auditor specified. Rather than mutating the stored envelope, it **removes the envelope artifact from the registry entirely**, demonstrates that issuance then fails closed with `unknown_envelope`, and runs the complete signed ALLOW/DENY decision battery while the artifact remains absent, restoring it afterwards. Removal demonstrates that admission does not depend on registry availability. A static phase-separation stage additionally parses the `mint_ect` and `_probe_impl` function bodies, enforces required constructs in issuance and forbidden constructs in admission, and therefore establishes that registry content cannot participate in admission authority. A future reintroduction of envelope resolution or sponsorship reconstruction into the admission path fails the suite before any container starts.

## 7. Auditor error corrected by the maintainer

In the round-two discussion the auditor claimed that inconsistent replay state across Gatekeeper replicas could only cause over-denial. This is wrong. Deny-monotonicity holds for the replay set as an input to a single decision point, but single-use is a global uniqueness property: two replicas with divergent replay sets each accept the same `jti` once, which is an over-grant relative to the single-use rule. The maintainer identified the error and supplied the correct statement, now carried in `ARCHITECTURE.md` §12.1: Gatekeeper replicas require no shared governance or authorization state, while strict cross-replica single-use DPoP requires a consistent replay domain or deterministic routing.


## 8. Residual notes (not findings)

Two items are recorded for maintenance, neither contradicting a claim.

1. Issuance establishes authority, but the reference implementation does not currently claim complete issuance-event evidencing. Mint grants and refusals are not represented as signed decision records. Issuance evidencing is therefore recorded as future work rather than as an admission-conformance requirement.

2. Maintainer-designated pre-inception housekeeping: the KYO phone-verification flow, bench instrumentation woven through the admission hot path, per-script duplication of DPoP/mint/verify plumbing across the Test5* suite, the historical `fcac`/`vfp` naming, and retirement of the `GuestContributionProbe` mirror class in favour of constructing `ProbeReq` directly.

## 9. Method of verification and closure

The audit combined static analysis, isolated execution of extracted logic, adversarial controls, and maintainer-executed conformance runs. The external reviewers did not themselves execute the deployed stack; runtime results below are maintainer-reported and preserved by the repository tests and refreshed evidence artefacts.

Runtime closure was established on 31 August 2026. `Test2E` passed the issuance/admission phase-separation test, including envelope-registry removal. `Test4C` passed the sponsorship regression path, including the Mode 1A governance aperture. `Test0C_delivery_regression.sh` completed with all delivery gates green, including Hal isolation, Hal credential admission, Table 7 decision-plane conformance, and Mode 1B governance composition. `Test5D` was rerun against the final implementation and refreshed the signed decision identifiers preserved in `JMIR_paper/table7/Test5D_mode1b_conformance.txt`.

No audit finding remains open at `1d395d7`.

## 10. Method and responsibility

Generative AI systems were used as reviewing instruments throughout this audit chain (OpenAI GPT-5.6 Sol High, Anthropic Opus 5 High and Fable 5): forensic code reading, claims-versus-implementation grading, counterfactual and adversarial challenge, patch drafting, and isolated verification of extracted logic. Their outputs were treated as provisional findings, not authoritative verdicts. Scoping of each review, adjudication of every finding, acceptance or replacement of every proposed fix, execution of the conformance suite, and this record's final content remained under the responsibility of the maintainer. 

Both resolutions of substance are the maintainer's own designs, adopted after rejecting the auditor's proposals as solving a different problem: full candidate-W verification at the Gatekeeper (F-1) in place of a manifest-based content commitment, and phase separation (R-1) in place of envelope content-binding. One auditor claim was factually wrong and was corrected by the maintainer (§7). The division of responsibility this record documents is therefore not nominal: the reviewer's role was to establish where the artifact contradicted itself; the architecture, the repairs, and the corrections are the author's.

The approach followed by the maintainer is described in the paper [Asymmetric Communication](https://arxiv.org/abs/2607.28137).

## 11. Limits

This record supports the statement: *audited to a fixed point by the reviewers applied* — successive independent reviews, each covering ground the previous ones did not, repeated until a round produced no findings. It does not support the word "verified" in any formal sense, and it does not preclude a differently scoped review finding something further. Per-record evidence authenticity is claimed and tested; evidence completeness is not claimed ([ARCHITECTURE](ARCHITECTURE.md) §25). The isolation claim for the agent environment is the narrow one stated in [MODE1B](MODE1B.md) §13, not general hostile-code containment. Stateless admission is claimed in the scoped sense of §12.1, not as an absence of all runtime state.

> Anyone disputing the claims is invited to do what this audit did: pick a forbidden simplification from [GOVERNANCE_COMPOSITION](GOVERNANCE_COMPOSITION.md) §13, or reintroduce governance-state resolution into the admission path, apply it as a mutation, and name the test that goes red and for what reason.

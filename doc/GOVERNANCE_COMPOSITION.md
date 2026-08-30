# Governance Composition in OpenHealth-CDI Mode 1B

## 1. Purpose

Mode 1B is not implemented with a Category Theory library, a `compose()` function, or a special-purpose formal language. Its governance semantics are expressed by the relations that the program preserves between governed values, actors, admissible operations, decisions, and evidence. This distinction is important. Category Theory supplies the semantic model. Python, HTTP, JSON, cryptographic evidence, and the Hub/Gatekeeper implementation supply one executable realization of that model. The implementation therefore does not depend on a particular programming language. What must be preserved is the relational structure. A port or refactor may change implementation language, framework, service topology, or internal organization while remaining semantically equivalent. It ceases to demonstrate the Mode 1B claim when it collapses relations that the experiment requires to remain independently observable.

## 2. The theoretical basis

The theoretical basis used here is the Value–Identity Model introduced in:

Enzo Fenoglio and Philip Treleaven, “Federated computing: information integration under sovereignty constraints,” *Royal Society Open Science*, 13(2), 251318, 2026. DOI 10.1098/rsos.251318.

The paper models governed values in a slice-category setting and introduces three governance primitives:

- **Bind** wraps a value with an owner-fixed sovereignty envelope.
- **Unbind** applies a lossy projection `τ: V → W` while preserving governance compatibility.
- **Rebind** keeps the value fixed while tightening its governance envelope.

For Mode 1B the relevant operation is Unbind.

Conceptually:

```text
(V, σV) ──Unbindτ──▶ (W, σW)
```

with a lossy projection:

```text
τ: V → W
```

and governance compatibility:

```text
σW ∘ τ = σV
```

The value changes from `V` to `W`. Governance is not discarded.

This is why image blur or pixelation in Mode 1B is an Unbind operation rather than a Rebind operation.

> Terminology used in the JMIR paper. The accompanying [JMIR manuscript](JMIR_MI_Manuscript_final.pdf) retains the term ***Rebind*** in a broader operational sense to describe the production of a derivative representation under an applicable governance relation. This usage is intentionally less formal than the terminology adopted by the reference implementation. In the VIM terminology used in this repository, a value-changing transformation V -> W is an ***Unbind***, whereas Rebind preserves the value while changing or tightening its governance envelope. The two operations are distinct. Under the policy-alignment condition defined in the VIM formalization, compatible Unbind and Rebind operations commute, so tightening before projection and tightening after projection yield the same final governed object. The repository therefore uses unbind for the implemented V -> W transformation, while the JMIR paper retains rebind as the more familiar operational term.

## 3. Category Theory is semantic, not syntactic

Nothing in the implementation requires Python specifically, and nothing in the semantics requires a Category Theory library.

A program realizes the categorical structure when it preserves the relevant objects, arrows, domains, codomains, and compositions.

For example:

```text
Audrey ──query──▶ V
Hal    ──Unbindτ──▶ W
Audrey ──consume──▶ W
```

The implementation is correct because these relations remain distinct and are evaluated independently.
Writing the same program in Rust, Java, Haskell, OCaml, Python, or another language would not change the governance model if the same observable relations were preserved.
Conversely, a program written in a language with strong functional or categorical abstractions would not automatically preserve the model if it collapsed those relations.

The semantics are therefore language-independent.

## 4. Could Coq have been used?

Yes, but for a different purpose.
Coq could formalize the governance model, define the relevant relations, state the composition rules, and mechanically prove properties such as:

```text
ALLOW(Hal, Unbindτ(V))
does not imply
ALLOW(Audrey, consume(W))
```

or:

```text
W_created = W_named = W_released
```

under an appropriate formal model.

A Coq development could also prove that a transition system implementing Mode 1B preserves selected invariants. Verified code could in principle be extracted into OCaml or another supported target. However, using Coq would not remove the need to implement the operational relations at the system boundary. The running system still has to:

```text
receive a request
obtain a governance decision
perform the authorized transformation
construct W
identify W
obtain a fresh decision concerning W
release or withhold W
record evidence
```

The cryptographic identities, HTTP calls, external model execution, container isolation, service discovery, and failure handling remain operational concerns.
Coq could therefore strengthen the proof of the abstract composition. It would not replace the composition itself.
The important result demonstrated by the PoC is more general. A particular language is not what creates the governance semantics. The semantics arise from the relations preserved by the implementation.

## 5. The simple Mode 1B example

Assume Audrey asks for a cancer image `V`.
Audrey is not permitted to consume the source image.

```text
Audrey ──query──▶ V
        DENY
```

The system does not therefore return `V`.
Hal may instead be authorized to perform a bounded transformation.

```text
Hal ──bounded inference──▶ operation
    ALLOW
```

Hal selects a permitted lossy transformation such as image blur.
The selection is not itself authorization. A separate governance decision authorizes the Unbind operation:

```text
Hal ──Unbindτ──▶ W
    ALLOW
```

Only after that decision does the Hub construct the governed derivative:

```text
W = τ(V)
```

Audrey must then be independently authorized to consume that particular governed derivative:

```text
Audrey ──consume──▶ W
        ALLOW
```

Only then is `W` released. The composed execution is:

```text
Audrey requests V
→ source DENY
→ Hal bounded inference ALLOW
→ Hal Unbindτ(V) ALLOW
→ construct W = τ(V)
→ Audrey consume(W) ALLOW
→ release W
```

## 6. Why the second admission is not redundant

A conventional implementation might appear simpler:

```text
if Audrey may receive blurred images:
    blur V
    return result
```

That program can return a blurred image, but it no longer demonstrates the governance composition.

It cannot independently establish:

```text
who was authorized to transform V
which transformation was authorized
which concrete W was produced
whether Audrey was independently authorized to consume W
whether the W named by the decision is the W that was released
```

The apparent redundancy in Mode 1B is therefore evidentiary structure. The two relations:

```text
Hal ──Unbindτ──▶ W
```

and:

```text
Audrey ──consume──▶ W
```

must remain independently observable because they express different authorities. The central invariant is:

```text
ALLOW(Hal, Unbind)
≠
ALLOW(requester, consume W)
```

## 7. The Charlie counterexample

The distinction becomes clearer with Charlie. Charlie is not authorized to consume the resulting derivative. The first part of the execution can still succeed:

```text
Charlie ──query──▶ V
        DENY

Hal ──bounded inference──▶ operation
    ALLOW

Hal ──Unbindτ──▶ W
    ALLOW
```

But the fresh consumption decision is:

```text
Charlie ──consume──▶ W
        DENY
```

Therefore:

```text
WITHHOLD W
```

This demonstrates that successful transformation authority does not confer release authority. If the implementation were reduced to:

```text
if transformation_allowed:
    return transformed_result
```

the Charlie case would disappear as a separately expressible governance relation. The code might become shorter. The scientific claim would no longer be observable.

## 8. Exact-W and identifiable composition

A further issue arises if the policy speaks only about a class such as `derivative`. The relation:

```text
consume(Audrey, derivative)
```

describes a policy relation over a class of objects.

Mode 1B needs to demonstrate a stronger operational statement:

```text
consume(Audrey, W123)
```

where `W123` is the concrete governed value created during this execution. The Hub therefore constructs the governed value and assigns it a content-addressed identity.

Conceptually:

```text
W123 = sha256(canonical(W))
```

The `value_id` is calculated over the canonical governed value rather than merely over the transformed image bytes. The signed consumption decision names that exact identifier. The released object carries the same identifier. This creates the executable invariant:

```text
W_created
=
W_named_in_signed_decision
=
W_released
```

For `consume_derivative`, the candidate governed value `W` is presented to the Gatekeeper before release. The Gatekeeper first evaluates the requester's capability relation and, only for a candidate operation that otherwise matches that capability, independently checks that `W` names the same resource, requested tissue, and derivative representation as the request. It then recomputes the content address of canonical `W`, verifies the derivative-image bytes against `derivative_sha256`, and returns ALLOW only when these checks succeed.

A successful signed consumption decision carries the exact governed value that the Gatekeeper verified together with its verified `governed_value_id`. An auditor can therefore recompute the content address from the signed evidence itself. Candidate governed values are not persisted in DENY evidence. Immediately before release, the Hub independently recomputes both the content address and derivative-byte digest once more. The resulting chain is:

```text
W_created
=
W_verified_by_Gatekeeper
=
W_evidenced
=
W_released
```

Without exact-W identity, an implementation could authorize one derivative and accidentally release another derivative of the same class while still appearing policy-compliant. Content addressing does not make the object the centre of the architecture. It makes the endpoints of the relations identifiable so that composition becomes traceable and falsifiable.

## 9. Where governance composition is implemented

There is no single composition operator in the code. The Hub realizes composition by preserving the dependency between independently governed operations. Conceptually the orchestration is:

```text
decision(source, V)
        ↓
decision(Unbind, V)
        ↓
construct W
        ↓
decision(consume, W)
        ↓
release W
```

The output of one relation becomes the input to the next. The crucial transition is:

```text
Unbind(V) → W
```

followed by:

```text
consume(requester, W)
```

The same exact `W` therefore connects the two arrows. This is ordinary program control flow implementing categorical composition.

## 10. Simplified implementation mapping

The source relation is evaluated first:

```python
source_admission = admit_principal_operation(
    principal=requester,
    action="query_model",
    resource="pathmnist-colon-pathology",
    requested_tissue=requested_tissue,
)
```

If source access is ALLOW, the source path may terminate normally. If it is DENY, Hal's bounded operation is separately admitted:

```python
hal_admission = admit_principal_operation(
    principal="Hal",
    action="bounded_inference",
    ...
)
```

The selected Unbind operation is then independently admitted:

```python
unbind_admission = admit_principal_operation(
    principal="Hal",
    action="unbind",
    derivative_representation="blur_image",
    ...
)
```

After ALLOW, the Hub constructs `W` and computes its identity:

```python
governed_value_bytes = json.dumps(
    governed_value,
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=False,
).encode("utf-8")

governed_value["value_id"] = (
    "sha256:" + hashlib.sha256(governed_value_bytes).hexdigest()
)
```

The requester is then separately admitted to consume that exact value:

```python
consume_admission = admit_principal_operation(
    principal=requester,
    resource="pathmnist-derived-representation",
    action="consume_derivative",
    governed_value_id=governed_value["value_id"],
    ...
)
```

Release occurs only if this fresh decision is ALLOW. The code therefore realizes:

```text
DENY(V)
→ AUTHORIZE Unbindτ(V)
→ W = τ(V)
→ FRESH GOVERNANCE DECISION consume(W)
→ RELEASE / WITHHOLD
```

## 11. Composition is an executable research claim

Several implementation boundaries are also measurement boundaries. Mode 1B must preserve independent observability of:

```text
source admission
Hal bounded-operation admission
Unbind admission
construction and identity of W
requester consume(W) admission
release or withholding of the same W
```

These stages are not accidental implementation ceremony. They are the points at which the experiment observes the relations needed to support the governance claim. This is why Test5E is more than a conventional regression test. It is an executable proof obligation for the composed Mode 1B path. A refactor remains equivalent only if these relations remain independently demonstrable.

## 12. What may be optimized

The implementation can and should be optimized where the optimization removes accidental complexity without collapsing governance relations.

Safe optimization targets include:

- extracting repeated credential and admission plumbing into reusable functions;
- representing the governed derivative as a dedicated immutable model;
- centralizing canonical serialization and `value_id` calculation;
- representing the Mode 1B execution context explicitly rather than passing many independent arguments;
- separating orchestration from HTTP transport details;
- reducing duplicated ALLOW/DENY response construction;
- making readiness and backend state explicit;
- replacing deeply nested branches with a clear state-machine or staged pipeline;
- using typed result objects for source admission, Unbind admission, governed-value construction, consume admission, and release;
- improving names so that the code exposes the relational structure directly.

A possible structural decomposition is:

```text
admit_source(requester, V)
        ↓
admit_hal_operation(Hal, V)
        ↓
admit_unbind(Hal, V, τ)
        ↓
construct_governed_value(V, τ) → W
        ↓
admit_consumption(requester, W)
        ↓
release_or_withhold(W)
```

This can make the code substantially easier to read while preserving every evidentiary boundary.

## 13. What must not be optimized away

The following apparent simplifications would invalidate or weaken the Mode 1B claim:

```text
combine source and derivative authority
combine Unbind authorization and requester consumption authorization
return W immediately after successful Unbind
replace exact-W identity with derivative-class checking
allow Hal's authority to imply requester authority
replace the fresh consume(W) decision with a cached generic permission
construct a different W after the consumption decision
release a value not named by the signed decision
erase the distinction between transformation and release evidence
```

The governing rule for refactoring is therefore:

> Do not preserve the current code structure merely because it exists. Preserve the observable relations and their composition.
A shorter implementation is desirable if it preserves those relations.
A shorter implementation that collapses them is not an optimization of the same experiment. It is a different experiment.

## 14. Porting rule

The AWS port does not need to reproduce the Python implementation line by line.

It must reproduce the relational contract:

```text
source authority
≠
transformation authority
≠
derivative-consumption authority
```

and:

```text
W_created
=
W_evidenced
=
W_released
```

The target implementation may use different services, languages, deployment mechanisms, or cloud primitives. The Mode 1B claim survives if these relations remain independently observable and the executable conformance tests can still demonstrate them.

## 15. Summary

Category Theory is foundational to Mode 1B, but it is not present as decorative syntax and does not require a Category Theory programming library. The categorical model tells us what relations must exist and how they compose. The implementation realizes those relations using ordinary software mechanisms. Coq could formalize and mechanically prove properties of the abstract model, but it would not change the operational need to realize the same governed relations in the running system.

The central lesson is:

```text
Do not preserve objects or code structures for their own sake.
Preserve the arrows that make the governance claim observable.
```

In Mode 1B those arrows become experimentally traceable because their concrete endpoint `W` is content-addressed and because transformation, consumption, and release remain distinct governed operations.

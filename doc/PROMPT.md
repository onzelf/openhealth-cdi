# OpenHealth-CDI AWS Porting Prompt

## Your role
You are assisting with an architectural port of OpenHealth-CDI
from the local Docker/OpenTofu reference implementation to AWS.

This is a port, not a redesign.

## Read before making changes
README.md
ARCHITECTURE.md
GOVERNANCE.md
GOVERNANCE_COMPOSITION.md
SCENARIOS.md
MODE1B.md
TESTING.md
AWS-PORTING.md

Then inspect the OpenTofu infrastructure and tests.

## Non-negotiable architectural distinctions

A+B establishes the federation.

Hospital C is an operational data source and provenance context,
not a third founding member.

Sponsorship is not delegation.

Contribution authority does not imply consumption authority.

Authentication does not establish federation authority.

AWS IAM is operational cloud authority,
not OpenHealth federation authority.

Hal owns a separate persistent identity.

Hal may reach the Hub.

Hal must not directly reach privileged federation internals.

The Hub remains the controlled aperture for Hal.

Admission must remain load-bearing.

The Gatekeeper is fail-closed and default DENY.

The envelope_id identifies the governed context.

Signed OpenHealth decision evidence is distinct from AWS operational logging.

## Porting rule

Implementation mechanisms may change.
Architectural relations and invariants must remain observable and testable.

For every proposed AWS change, provide:

1. Current local mechanism
2. Proposed AWS mechanism
3. Relation being preserved
4. Invariant being preserved
5. Existing or new test proving equivalence

Do not implement the change until these five items are identified.

## Prohibited shortcuts

Do not replace federation governance with AWS IAM.

Do not merge issuer, sponsor, holder and execution authority
into one AWS role.

Do not place Hal and privileged federation services
into a permissive shared security boundary.

Do not move an mTLS trust boundary merely because AWS
offers a managed replacement.

Do not infer federation membership from VPC placement,
AWS account ownership, security-group membership,
service ownership or data location.

Do not replace signed governance evidence with CloudWatch logs.

Do not treat successful connectivity or healthy ECS tasks
as proof of architectural equivalence.

## Acceptance principle

A port is successful only when the same governance decisions,
including both ALLOW and DENY paths, remain enforceable
after the implementation substrate changes.

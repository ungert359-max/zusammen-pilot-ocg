# OCG Core Preservation Policy

## Purpose

The Aachen pilot uses upstream Open Community Groups (OCG) as the professional foundation. Local work must minimize newly introduced defects by preserving upstream code wherever possible and keeping pilot-specific behavior isolated.

## Binding rules

1. **Reuse before rewrite.** If OCG already provides a suitable function, use it directly instead of reimplementing or porting it.
2. **No language-driven rewrites.** Existing Rust, JavaScript, PL/pgSQL or other upstream code is not rewritten merely to standardize the stack.
3. **Upstream core is immutable by default.** Pilot-specific changes must not modify OCG application, database, chart, or other upstream core files.
4. **Additions stay isolated.** Aachen-specific implementation belongs under `pilot/aachen/**`; Aachen CI/control logic belongs in the dedicated Aachen workflows.
5. **Adapters before invasive changes.** New behavior should be connected through configuration, APIs, adapters, isolated services, migrations, or other narrow boundaries rather than edits to upstream business logic.
6. **Tests are additive.** Existing upstream tests must not be removed, weakened, or bypassed. New pilot behavior gets its own validation and regression coverage.
7. **Fail closed.** A local change outside the explicitly allowed pilot paths is treated as a policy violation until deliberately reviewed and justified.
8. **Upstream updates remain upstream.** Changes to OCG core should arrive by synchronizing the fork's `main` branch with the upstream CNCF repository, not by locally recreating them in the pilot branch.
9. **Release only on verified PASS gates.** A pilot addition is not considered releasable merely because it builds; the applicable validation, smoke, security, and deployment gates must pass.
10. **Database-cost and failure isolation are activation requirements for Map/Explore enrichments.** An optional pilot feature that adds database work to discovery must remain independently disableable and may not enter the availability chain of the normal OCG map.
11. **Preserve upstream ticketing and payments.** The existing OCG ticketing, checkout, payment, platform-fee, refund, ticket-tier, discount, invitation, waitlist and related test code must not be deleted, stripped, weakened or replaced merely because paid ticketing is not used in the first Aachen pilot. For the pilot, this capability is disabled by configuration only. Reactivation requires separate explicit approval and its own payment/ticketing validation gate.

## Ticketing preservation and pilot lockout

The current strategic decision is to keep the complete upstream ticketing/payment capability available for later organizer acquisition and monetization experiments while leaving it unused during the initial Aachen pilot.

Binding consequences:

- `pilot/aachen/values-pilot.yaml` keeps `payments.enabled: false` for the initial pilot.
- Disabling paid ticketing must be achieved through configuration/feature gating, never by deleting the underlying implementation.
- Upstream ticketing/payment/refund migrations, handlers, UI paths, tests and documentation remain part of the preserved OCG core.
- No real-money ticketing, Stripe activation, payout setup or platform-fee charging is permitted in the initial pilot without separate explicit approval.
- Future activation requires dedicated end-to-end validation for checkout, duplicate/retry handling, webhook/idempotency behavior, seat holds/capacity contention, refunds, event cancellation, provider failures and recovery before any real-money pilot is opened to organizers.

### Binding database-query principle

**Wir bauen es so, dass es erst aktiviert werden darf, nachdem bewiesen wurde, dass die konkrete Abfrage billig ist, und dass es im Fehlerfall automatisch vom eigentlichen OCG-Kartenbetrieb isoliert werden kann.**

For Map/Explore enrichments this means, at minimum: the concrete SQL is measured on realistic data; required indexes are verified; work is bounded to the relevant result set; N+1 query patterns are prohibited; unnecessary queries are skipped; request bursts and stale work are controlled; the optional path has an appropriate scoped timeout; and a feature flag/kill-switch plus tested graceful degradation leaves the base OCG Explore/Map path working when the enrichment fails or is disabled.

The authoritative activation checklist is `docs/decisions/map-query-cost-and-isolation-gate.md`. Missing evidence means the enrichment stays OFF.

## Current allowed local surfaces

- `pilot/aachen/**`
- `.github/workflows/aachen-*.yml`
- `.github/workflows/pilot-validate.yml`

Anything else is blocked by the core-preservation CI guard.

## Exception rule

If an upstream core modification ever becomes technically unavoidable, it must be handled as an explicit exception: documented reason, minimal patch, dedicated regression tests, separate review, and a clear explanation of why an adapter or isolated addition was insufficient. The default remains **do not modify upstream OCG core**.

The DB-cost and Map-isolation gate is not waived by an upstream-core exception. Any query newly introduced or materially changed for an Aachen Map/Explore feature still requires its own measured activation proof and tested isolation path.

The ticketing-preservation rule is also not waived implicitly by a pilot simplification. Any proposal to remove or materially weaken the existing upstream ticketing/payment/refund capability requires a separate explicit decision; absence of pilot usage is not sufficient justification.

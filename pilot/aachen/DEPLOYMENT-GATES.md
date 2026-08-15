# Aachen Pilot Deployment Gates

This file tracks the minimum technical gates before the Aachen pilot is exposed publicly.

## Current status

- [x] Pilot branch exists (`pilot-aachen-mvp`).
- [x] Pilot Helm overrides exist without committed credentials.
- [x] Helm dependencies resolve.
- [x] Helm lint passes with the Aachen overrides.
- [x] Kubernetes manifests render successfully.
- [x] Database migrator container builds successfully in GitHub Actions.
- [x] Application container builds successfully in GitHub Actions.
- [x] k3s secrets encryption at rest is confirmed `Enabled` before private deployment secrets are written to the cluster.
- [x] Runtime smoke test starts PostgreSQL, runs migrations, starts OCG and returns a successful `/health-check` response without public Ingress.
- [x] Upstream ticketing/payment/refund capability is preserved in the codebase while Aachen pilot payments remain disabled by configuration.
- [ ] Minimum CPU, RAM and storage for the pilot host are confirmed from a dedicated capacity/load test. The successful runtime smoke measured the current host and pods, but that measurement is not a minimum-capacity proof.
- [x] Public pilot host is provisioned, while the OCG pilot runtime remains private/no-Ingress.
- [ ] Domain and HTTPS are connected. This remains blocked until separately approved.
- [ ] Transactional email is connected and signup/login flows are tested. Real email remains blocked until separately approved.
- [ ] Organizer-created event, RSVP, capacity, waitlist and check-in are verified end to end against the private pilot runtime.
- [ ] Every Aachen-specific Map/Explore enrichment that adds database work has passed the binding DB-cost and isolation gate in `docs/decisions/map-query-cost-and-isolation-gate.md` before its feature flag is enabled.
- [ ] Paid ticketing has separate explicit approval and has passed its dedicated checkout/payment/refund/idempotency/capacity/recovery validation gate before any real-money use.

## Last known good runtime

The current fully verified private runtime control stand is:

- Control commit: `36ebb0d0f1568772be94013df566b0b6f78d13ed`
- Host image build basis: `696dfe8b100f15f2a5488d4841de5bfa344339be`
- PostgreSQL image digest: `sha256:c6c4e196d49182e54c7951fa629f5bce71e7ff7f17610f6960251cfeefbea4eb`
- Server image digest: `sha256:c269e39c80f94a8defe53cf543aba367542faf94fe266abc53c18411fcfe71c5`
- Migrator image digest: `sha256:b70a2505bd92b9ba74ee885a0026af8855595601a78c59c68d72c38458f0cbb7`

For that exact control/image combination, GitHub Actions evidence is green for Aachen pilot validation, upstream-core integrity and the private exact-image runtime smoke. The smoke explicitly reported `PASS: PostgreSQL/migration/server startup and /health-check succeeded without public Ingress.`

The successful smoke recorded PostgreSQL `1/1 Running`, the migration pod `Completed`, the server `1/1 Running`, zero restarts for all three, and the PostgreSQL PVC `Bound` at 8 GiB. The same run measured PostgreSQL at approximately `99m` CPU / `141Mi` memory and the server at approximately `18m` CPU / `13Mi` memory. These measurements are operational evidence only and must not be treated as a validated minimum hardware profile.

## Rules

- Keep `main` close to upstream OCG.
- Put Aachen-specific work on `pilot-aachen-mvp`.
- Do not commit passwords, private keys, SMTP credentials or other deployment secrets.
- Keep deployment secrets in a local values file outside the Git repository or an equivalent secret store.
- Do not write OCG deployment secrets into the k3s datastore unless secrets encryption at rest is confirmed enabled.
- Do not change the separate `app-mobile-greenfield` repository as part of this pilot.
- Do not connect the public domain, enable public Ingress, activate real transactional email or collect real user data without separate explicit approval.
- Do not activate a Map/Explore enrichment merely because it builds or appears correct. Its concrete database query and its failure-isolation path must be measured and verified first.
- Do not promote a new control or image stand over the last known good runtime until all regression-relevant gates for that change are green.
- Do not delete, strip, bypass or weaken upstream ticketing/payment/refund code merely because it is unused in the initial pilot. Keep it present and disable paid ticketing only through configuration.
- Keep `payments.enabled: false` for the initial Aachen pilot. Enabling Stripe, real-money checkout, payouts or platform fees requires separate explicit approval and a dedicated payment/ticketing gate.

## Binding DB-cost and Map-isolation gate

**Wir bauen es so, dass es erst aktiviert werden darf, nachdem bewiesen wurde, dass die konkrete Abfrage billig ist, und dass es im Fehlerfall automatisch vom eigentlichen OCG-Kartenbetrieb isoliert werden kann.**

For every optional Map/Explore enrichment, activation is blocked until the concrete query has been measured on realistic pilot data, required indexes are verified, the work is bounded and non-N+1, a short scoped timeout exists, stale/request-burst work is controlled, and a feature flag or kill-switch can remove only the enrichment. Failure, timeout, overload or manual disablement of the enrichment must leave the normal OCG Explore/Map path operational.

The disable/rollback path and graceful degradation must be tested before first activation. The complete binding criteria live in `docs/decisions/map-query-cost-and-isolation-gate.md`.

## Existing upstream product-E2E baseline

The upstream OCG test suite already contains concrete synthetic E2E coverage for the core journey needed by the Aachen pilot. This is useful baseline evidence that the required OCG product paths exist before any Aachen-specific product change is considered:

- `tests/e2e/workflows/events/events.spec.js` creates an organizer event through the dashboard, verifies the created row, and exercises deletion cleanup. The broader suite also verifies attendee-count/capacity behavior.
- `tests/e2e/workflows/rsvp/rsvp.spec.js` verifies an approval-required RSVP flow through offer claim/checkout.
- `tests/e2e/workflows/waitlist/waitlist.spec.js` verifies waitlist join, promotion after capacity is released, and offer claim through checkout.
- `tests/e2e/site/event/check-in.spec.js` verifies registration before check-in, organizer-side check-in, the public check-in form, and the visible checked-in success state.
- The relevant flows use synthetic seeded E2E users/data and local test infrastructure; they are not evidence that the private Hetzner pilot runtime itself has completed the same product journey.

The upstream codebase also contains payment/refund E2E coverage. That coverage is preserved, but payments remain intentionally disabled in the first Aachen private product gate. Preserving the tests is part of preserving the later ticketing option; it does not authorize real-money use in the pilot.

The pilot now also contains isolated preparation and loopback-only runner controls under `pilot/aachen/private-product-e2e-prepare.sh` and `pilot/aachen/private-product-e2e-run.sh`. They remain separate from the known-good smoke namespace, require private `ClusterIP`/no-Ingress operation, use only committed synthetic fixtures, and keep payments/meetings disabled for this first product gate.

Accordingly, the private-runtime E2E checkbox above remains intentionally **unchecked** until the complete selected journey has actually passed against the private pilot runtime. No Aachen product behavior, UI, database schema or upstream core code needs to be changed merely to execute this gate.

## Immediate next gate

Keep the verified runtime/image combination above as the rollback reference. The remaining non-Core product gate is to execute the already-prepared synthetic journey against the private pilot runtime through the loopback-only runner: organizer-created event, RSVP/capacity/waitlist and check-in, without public Ingress, real email, paid services or real user data.

Reuse the upstream E2E contracts above as the expected behavior rather than inventing a parallel Aachen product implementation. Any failure must first be isolated to pilot configuration, CI/deployment or an additive Aachen adapter. If correcting it would require a change to `ocg-server/**`, `ocg-common/**`, `ocg-redirector/**`, `database/migrations/**` or visible OCG product/UI logic, stop before that change and require separate approval.

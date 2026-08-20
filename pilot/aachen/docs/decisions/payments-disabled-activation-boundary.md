# Payments disabled activation boundary

## Status

This decision applies to the Aachen feature basis while real payment activation is intentionally disabled.

- `verified-ocg-stable` is the immutable verified reference and is not a payment-development branch.
- Payment, paid-ticket, checkout, refund, discount, provider and webhook code remains present on the feature basis for later use.
- The Aachen pilot must remain fail-closed with payments disabled until a separate explicit activation decision and a new activation-specific verification cycle.
- This document contains no provider credentials or secret values.

## Current disabled-state contract

The Aachen pilot must satisfy all of the following while payments are OFF:

1. `pilot/aachen/values-pilot.yaml` keeps `payments.enabled: false`.
2. The final private runtime render contains no active payments configuration and no payment-provider credentials.
3. Missing or invalid provider configuration never creates a usable provider integration.
4. No productive payment webhook is configured or exposed for the pilot.
5. No real charge, refund, payout or other provider transaction is executed as part of disabled-state verification.
6. Provider-dependent real payment E2E remains `DEACTIVATED/NOT_VERIFIED`; it must never be reported as PASS without an explicitly authorized provider test environment.
7. Free event flows must continue to work without a payment provider, including free ticket checkout where the upstream implementation uses the checkout state machine for a zero-price ticket.

## Preserved upstream payment surface

The feature basis intentionally preserves the upstream payment architecture instead of replacing it with pilot-specific payment code. This includes, as applicable in the upstream tree:

- paid ticket and ticket-price state;
- checkout and purchase-hold state;
- discount-code handling;
- refund request and refund processing state;
- payment-provider abstractions and the Stripe implementation;
- payment webhook handling;
- refund workers/reconciliation;
- database payment/purchase records and state transitions.

The existence of this code is not an activation signal.

## Fail-closed invariants already established

The disabled-state integration must retain these invariants:

- No payment provider is constructed from an absent payments configuration.
- Provider-required operations fail closed when no provider is configured.
- A persisted provider checkout URL must not be returned when no provider is currently configured; reusing such a URL is allowed only when a provider is actually configured.
- The payment webhook must not be registered as an active payment integration when payments configuration is absent.
- Pilot validation and private deployment checks must reject accidental payment-provider credentials or an active payment render while the pilot is configured OFF.

## Reviewed core exception patch

Configuration and the Helm adapter remove the provider configuration, but they cannot neutralize
provider URLs and paid-state fields already persisted in PostgreSQL before payments are disabled.
They also cannot prevent the upstream refund command from performing database work before it
discovers that no provider exists. The fail-closed boundary therefore requires a narrowly scoped
pilot exception in exactly these upstream-core files:

- `ocg-server/src/handlers/event.rs`
- `ocg-server/src/services/payments/manager.rs`
- `ocg-server/src/services/payments/manager/tests.rs`
- `ocg-server/static/js/event/attendance/status-renderer.js`
- `ocg-server/templates/site/stats/page.html` (independent responsive-layout exception; see
  `stats-responsive-core-exception.md`)

Relative to reviewed upstream `main`, the complete binary-safe patch fingerprint is
`e27d74cfd7f3724ff38e28a01873e8a14298631e3e1c46230490388d572738b8`. The integrity gate
verifies this exact fingerprint; matching one of the paths is not sufficient. Any upstream rebase
or semantic change to the exception must fail closed and receive a new explicit review, updated
regressions and a new fingerprint. Fork `main` remains byte-for-byte upstream and never carries
this exception.

## Remaining hardening before `PAYMENT_INTEGRATED_BUT_DISABLED`

The following boundaries remain separate verification/work items and must not be treated as completed merely because the provider is OFF:

1. **Enrollment state / browser CTAs.** When payments are disabled, persisted legacy purchase data must not expose a resumable provider checkout URL or make a refund CTA usable. Payment-state fields required only for real paid flows should be masked or otherwise made non-actionable while preserving ordinary attendance/check-in state.
2. **Refund command boundary.** A refund request must fail closed before it can become a usable paid-flow command when payments are disabled. No real provider action may be attempted.
3. **Paid-ticket public UI.** Existing paid ticket configuration must not make paid-ticket selection, paid price badges, checkout CTAs or discount-code controls usable in the Aachen pilot while payments are OFF. Free ticket/RSVP behavior must remain available.
4. **Paid checkout hold boundary.** A paid ticket request while payments are OFF must not create a new paid provider-oriented purchase/hold state merely to fail later at redirect creation. Zero-price checkout behavior must remain intact.
5. **Background processing.** Refund/reconciliation/provider workers must remain inert with no provider configuration and must be covered by provider-independent verification where feasible.
6. **Free-path regression.** Core integrity, pilot validation, private runtime/health and the relevant free Event/RSVP/Waitlist/Check-in/Auth/Community/Group smoke/functional paths must remain green after each disabled-payment hardening change.

## Explicit activation boundary

Real payments may be considered for activation only after a later, explicit user decision. That future activation must be treated as a separate release gate and must include all of the following before any real user can pay:

1. Explicitly change the intended environment from payments OFF to payments ON; no implicit activation through code presence is allowed.
2. Configure the selected provider deliberately and only in the authorized secret/configuration store, never in repository files or logs.
3. Supply the provider credentials and webhook secret required by the selected provider implementation.
4. Configure and verify the productive webhook endpoint, signature verification and replay/idempotency behavior.
5. Verify provider account/recipient configuration, currency/amount semantics, platform-fee behavior and refund behavior for the intended deployment.
6. Re-run configuration/render/secret-leak checks and confirm that secrets are not committed or emitted to logs/artifacts.
7. Run provider-specific payment tests in an explicitly authorized non-production/test environment first, including successful checkout, failed/cancelled checkout, webhook delivery/retry, duplicate webhook/idempotency, refund and reconciliation cases.
8. Re-run all free core regression paths and verify that enabling payments does not regress free tickets, RSVP, Waitlist, Check-in, Auth, Community or Group functionality.
9. Perform a separate production-readiness review before any productive provider credentials, real webhook or real transaction is enabled.

Until every applicable activation item above is explicitly authorized and verified, the operational state remains **PAYMENTS OFF**.

## Completion rule for the current phase

This document alone does not make the phase complete. `PAYMENT_INTEGRATED_BUT_DISABLED` is reached only on one exact feature-basis commit where the disabled-state boundaries above are implemented as needed and the required provider-independent checks plus free-path regressions are evidenced as PASS. Provider-dependent real payment E2E remains separately `DEACTIVATED/NOT_VERIFIED` until a future authorized activation phase.

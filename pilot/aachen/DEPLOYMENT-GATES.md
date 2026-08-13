# Aachen Pilot Deployment Gates

This file tracks the minimum technical gates before public hosting is ordered.

## Current status

- [x] Pilot branch exists (`pilot-aachen-mvp`).
- [x] Pilot Helm overrides exist without committed credentials.
- [x] Helm dependencies resolve.
- [x] Helm lint passes with the Aachen overrides.
- [x] Kubernetes manifests render successfully.
- [x] Database migrator container builds successfully in GitHub Actions.
- [ ] Application container build completes successfully.
- [ ] Runtime smoke test starts PostgreSQL, runs migrations, starts OCG and returns a successful `/health-check` response.
- [ ] Minimum CPU, RAM and storage for the pilot host are established from the runtime test.
- [ ] Public host is provisioned.
- [ ] Domain and HTTPS are connected.
- [ ] Transactional email is connected and signup/login flows are tested.
- [ ] Organizer-created event, RSVP, capacity, waitlist and check-in are verified end to end.

## Rules

- Keep `main` close to upstream OCG.
- Put Aachen-specific work on `pilot-aachen-mvp`.
- Do not commit passwords, private keys, SMTP credentials or other deployment secrets.
- Do not change the separate `app-mobile-greenfield` repository as part of this pilot.
- Do not order public infrastructure before the local/runtime gates above have passed unless a gate explicitly requires it.

## Immediate next gate

Wait for the current application-container build to finish. If it succeeds, execute a temporary runtime smoke test. If it fails, inspect the failing build step and fix only the concrete blocker before continuing.

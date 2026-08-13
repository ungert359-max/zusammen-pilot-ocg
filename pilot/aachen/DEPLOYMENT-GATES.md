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
- [ ] Runtime smoke test starts PostgreSQL, runs migrations, starts OCG and returns a successful `/health-check` response.
- [ ] Minimum CPU, RAM and storage for the pilot host are confirmed from the runtime test.
- [x] Public pilot host is provisioned.
- [ ] Domain and HTTPS are connected.
- [ ] Transactional email is connected and signup/login flows are tested.
- [ ] Organizer-created event, RSVP, capacity, waitlist and check-in are verified end to end.

## Rules

- Keep `main` close to upstream OCG.
- Put Aachen-specific work on `pilot-aachen-mvp`.
- Do not commit passwords, private keys, SMTP credentials or other deployment secrets.
- Keep deployment secrets in a local, ignored values file or an equivalent secret store.
- Do not change the separate `app-mobile-greenfield` repository as part of this pilot.
- Do not connect the public domain until the runtime smoke test is green.

## Immediate next gate

Use the provisioned pilot host for a private runtime smoke test: install the single-node Kubernetes/Helm prerequisites, deploy PostgreSQL plus OCG with deployment-time-only credentials, run migrations, and verify `/health-check`. Only after that succeeds should the domain, HTTPS and transactional email be connected.

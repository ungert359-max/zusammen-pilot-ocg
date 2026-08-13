# Aachen Pilot

This directory contains public, non-sensitive configuration for the Aachen pilot based on Open Community Groups.

Pilot goals:
- email-based user registration
- local event discovery
- organizer-created events
- RSVP and capacity handling
- waitlist flow
- attendance/check-in
- basic analytics for market validation

The pilot intentionally keeps the upstream OCG codebase as unchanged as possible. Advanced custom product features are not part of this first deployment. The `pilot-aachen-mvp` branch currently differs from `main` only in pilot configuration, validation and deployment documentation; application source code is not modified for the pilot.

Branch strategy:
- `main` stays close to upstream OCG.
- `pilot-aachen-mvp` contains pilot-specific configuration.

Validation:
- `.github/workflows/pilot-validate.yml` checks the Helm chart with the Aachen overrides.
- the same workflow builds the application and database-migrator containers to catch deployment blockers before runtime deployment.
- the current CI baseline has passed Helm dependency resolution, Helm lint, manifest rendering, the database-migrator image build and the application image build.

## Private runtime smoke test

The next deployment step is deliberately private. Before connecting a public domain, deploy the chart on the provisioned single-node pilot host and verify that PostgreSQL becomes ready, migrations complete, OCG starts and `/health-check` responds successfully.

Deployment-time values must be supplied outside the public repository. At minimum, keep these values private:
- `db.password`
- the matching `postgresql.auth.password`
- `server.badges.signingKey`, containing an Ed25519 private JWK
- SMTP username/password once transactional email is enabled

Do not store the private deployment values file in this repository and do not paste its contents into issues, commits or CI logs. The database password used by OCG and the bundled PostgreSQL chart must match.

For the first runtime smoke test, keep the application ingress non-public and reach the service only through a local Kubernetes port-forward. After `/health-check` is green, confirm storage/resource usage and then proceed to the separate public-domain, HTTPS and transactional-email gates tracked in `DEPLOYMENT-GATES.md`.

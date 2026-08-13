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

The pilot intentionally keeps the upstream OCG codebase as unchanged as possible. Advanced custom product features are not part of this first deployment.

Branch strategy:
- `main` stays close to upstream OCG.
- `pilot-aachen-mvp` contains pilot-specific configuration.

External infrastructure such as a public host, domain and transactional email will be connected only after the application configuration has passed a smoke test.

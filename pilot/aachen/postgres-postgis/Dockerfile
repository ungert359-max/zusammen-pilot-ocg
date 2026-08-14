# Pilot-only database image for the Aachen runtime smoke test.
# Keep the inherited Artifact Hub PostgreSQL image exact and add only the
# extension required by the unchanged OCG schema migration.
FROM docker.io/artifacthub/postgres@sha256:411febeab51f103cd36aa8655bebb3c4035974e0d6f6929a56fe863ad8c581b6

USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-14-postgis-3; \
    rm -rf /var/lib/apt/lists/*

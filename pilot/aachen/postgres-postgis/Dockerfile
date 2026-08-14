# Pilot-only database image for the Aachen runtime smoke test.
# OCG's current migrations use PostgreSQL syntax introduced after PostgreSQL 14,
# and the upstream development toolchain targets PostgreSQL 17. Keep the database
# engine on an immutable Docker Official Image digest and add only PostGIS.
FROM docker.io/library/postgres@sha256:6b638839aa8ffdc0f1e186be8a04d544368b05110a314c40d3225a15e9c9c98d

USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-17-postgis-3; \
    rm -rf /var/lib/apt/lists/*

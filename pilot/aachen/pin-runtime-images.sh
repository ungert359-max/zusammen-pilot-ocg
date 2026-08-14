#!/usr/bin/env bash
set -Eeuo pipefail

# Helm 3 post-renderer for the private Aachen pilot. Keep the upstream
# Artifact Hub PostgreSQL base exact, but run the pilot-only derived image that
# adds PostGIS without modifying inherited OCG or chart templates. Helm 3 does
# not pass hooks through executable post-renderers, so hook lifecycle fixes are
# kept in the separate private smoke bootstrap instead of being pretended here.
POSTGRES_BASE_PIN='docker.io/artifacthub/postgres@sha256:411febeab51f103cd36aa8655bebb3c4035974e0d6f6929a56fe863ad8c581b6'
POSTGRES_RUNTIME_IMAGE='zusammen-pilot-postgres:local'
KUBECTL_PIN='docker.io/bitnamilegacy/kubectl@sha256:cd354d5b25562b195b277125439c23e4046902d7f1abc0dc3c75aad04d298c17'

tmp_in="$(mktemp)"
tmp_out="$(mktemp)"
cleanup() {
  rm -f "$tmp_in" "$tmp_out"
}
trap cleanup EXIT INT TERM

cat > "$tmp_in"
sed \
  -e "s#$POSTGRES_BASE_PIN#$POSTGRES_RUNTIME_IMAGE#g" \
  -e "s#docker.io/artifacthub/postgres:latest#$POSTGRES_RUNTIME_IMAGE#g" \
  -e "s#docker.io/bitnamilegacy/kubectl:1.33#$KUBECTL_PIN#g" \
  "$tmp_in" > "$tmp_out"

# Fail closed if reviewed mutable/external PostgreSQL helper references survive
# or if the local PostGIS-enabled image was not rendered.
if grep -Fq 'docker.io/artifacthub/postgres' "$tmp_out"; then
  echo 'Aachen post-renderer: external Artifact Hub PostgreSQL image survived rendering.' >&2
  exit 1
fi
if grep -Eq "docker.io/bitnamilegacy/kubectl:[^[:space:]\"]+" "$tmp_out"; then
  echo 'Aachen post-renderer: mutable kubectl helper image survived rendering.' >&2
  exit 1
fi

grep -Fq "$POSTGRES_RUNTIME_IMAGE" "$tmp_out" || {
  echo 'Aachen post-renderer: expected local PostGIS PostgreSQL image was not rendered.' >&2
  exit 1
}

cat "$tmp_out"

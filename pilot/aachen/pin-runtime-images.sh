#!/usr/bin/env bash
set -Eeuo pipefail

# Helm 3 post-renderer for the private Aachen pilot. The upstream chart reuses the
# PostgreSQL tag in readiness init containers and selects a tagged kubectl image
# for an install-only migration gate. Keep those regular install-time helper
# images immutable without modifying inherited chart templates. Helm 3 does not
# pass hooks through executable post-renderers, so hook lifecycle fixes are kept
# in the separate private smoke bootstrap instead of being pretended here.
POSTGRES_PIN='docker.io/artifacthub/postgres@sha256:411febeab51f103cd36aa8655bebb3c4035974e0d6f6929a56fe863ad8c581b6'
KUBECTL_PIN='docker.io/bitnamilegacy/kubectl@sha256:cd354d5b25562b195b277125439c23e4046902d7f1abc0dc3c75aad04d298c17'

tmp_in="$(mktemp)"
tmp_out="$(mktemp)"
cleanup() {
  rm -f "$tmp_in" "$tmp_out"
}
trap cleanup EXIT INT TERM

cat > "$tmp_in"
sed \
  -e "s#docker.io/artifacthub/postgres:latest#$POSTGRES_PIN#g" \
  -e "s#docker.io/bitnamilegacy/kubectl:1.33#$KUBECTL_PIN#g" \
  "$tmp_in" > "$tmp_out"

# Fail closed if reviewed mutable helper references survive rendering.
if grep -Fq 'docker.io/artifacthub/postgres:latest' "$tmp_out"; then
  echo 'Aachen post-renderer: mutable PostgreSQL helper image survived rendering.' >&2
  exit 1
fi
if grep -Eq "docker.io/bitnamilegacy/kubectl:[^[:space:]\"]+" "$tmp_out"; then
  echo 'Aachen post-renderer: mutable kubectl helper image survived rendering.' >&2
  exit 1
fi

grep -Fq "$POSTGRES_PIN" "$tmp_out" || {
  echo 'Aachen post-renderer: expected pinned PostgreSQL helper image was not rendered.' >&2
  exit 1
}

cat "$tmp_out"

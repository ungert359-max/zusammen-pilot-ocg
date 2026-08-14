#!/usr/bin/env bash
set -Eeuo pipefail

# Helm 3 post-renderer for the private Aachen pilot. Keep the inherited chart's
# reviewed PostgreSQL reference as a render-time sentinel, then replace it with
# the local PostgreSQL 17 + PostGIS image built from the independently pinned
# Dockerfile. No external database image is allowed to survive the transform.
# Helm 3 does not pass hooks through executable post-renderers, so hook lifecycle
# fixes remain in the separate private smoke bootstrap.
POSTGRES_RENDER_SENTINEL='docker.io/artifacthub/postgres@sha256:411febeab51f103cd36aa8655bebb3c4035974e0d6f6929a56fe863ad8c581b6'
POSTGRES_RUNTIME_IMAGE='zusammen-pilot-postgres:local'
KUBECTL_PIN='docker.io/bitnamilegacy/kubectl@sha256:cd354d5b25562b195b277125439c23e4046902d7f1abc0dc3c75aad04d298c17'

tmp_in="$(mktemp)"
tmp_mid="$(mktemp)"
tmp_out="$(mktemp)"
cleanup() {
  rm -f "$tmp_in" "$tmp_mid" "$tmp_out"
}
trap cleanup EXIT INT TERM

cat > "$tmp_in"
sed \
  -e "s#$POSTGRES_RENDER_SENTINEL#$POSTGRES_RUNTIME_IMAGE#g" \
  -e "s#docker.io/artifacthub/postgres:latest#$POSTGRES_RUNTIME_IMAGE#g" \
  -e "s#docker.io/bitnamilegacy/kubectl:1.33#$KUBECTL_PIN#g" \
  "$tmp_in" > "$tmp_mid"

# The PostgreSQL subchart uses the same database image in more than one
# container. Force every local pilot database image reference to Never so a
# missing host import fails instead of falling back to an unintended registry.
if ! awk -v image="$POSTGRES_RUNTIME_IMAGE" '
  /^[[:space:]]*image:/ && index($0, image) {
    postgres_image = 1
    print
    next
  }
  postgres_image && /^[[:space:]]*imagePullPolicy:/ {
    prefix = $0
    sub(/imagePullPolicy:.*/, "", prefix)
    print prefix "imagePullPolicy: Never"
    postgres_image = 0
    next
  }
  postgres_image && /^[[:space:]]*image:/ {
    exit 42
  }
  { print }
  END {
    if (postgres_image) exit 43
  }
' "$tmp_mid" > "$tmp_out"; then
  echo 'Aachen post-renderer: could not bind every local PostgreSQL image to imagePullPolicy Never.' >&2
  exit 1
fi

# Fail closed if reviewed mutable/external PostgreSQL helper references survive
# or if the local PostGIS-enabled image was not rendered.
if grep -Fq 'artifacthub/postgres' "$tmp_out"; then
  echo 'Aachen post-renderer: external Artifact Hub PostgreSQL image survived rendering.' >&2
  exit 1
fi
if grep -Eq 'docker.io/(library/)?postgres(:|@)' "$tmp_out"; then
  echo 'Aachen post-renderer: external Docker PostgreSQL image survived rendering.' >&2
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

# Verify the transformed manifest itself, not just the input values. Every local
# PostgreSQL image must be followed by a Never pull policy before another image.
if ! awk -v image="$POSTGRES_RUNTIME_IMAGE" '
  /^[[:space:]]*image:/ && index($0, image) {
    postgres_image = 1
    seen += 1
    next
  }
  postgres_image && /^[[:space:]]*imagePullPolicy:[[:space:]]*Never[[:space:]]*$/ {
    postgres_image = 0
    safe += 1
    next
  }
  postgres_image && /^[[:space:]]*imagePullPolicy:/ { exit 44 }
  postgres_image && /^[[:space:]]*image:/ { exit 45 }
  END {
    if (postgres_image || seen == 0 || safe != seen) exit 46
  }
' "$tmp_out"; then
  echo 'Aachen post-renderer: local PostgreSQL pull-policy verification failed.' >&2
  exit 1
fi

cat "$tmp_out"

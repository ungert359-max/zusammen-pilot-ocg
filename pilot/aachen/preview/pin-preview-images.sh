#!/usr/bin/env bash
set -Eeuo pipefail

# Preview-only Helm 3 post-renderer. This file exists only on the preview branch.
# It deliberately uses a unique PostgreSQL image name supplied by the preview
# workflow so the verified Aachen runtime image tags are never replaced.
POSTGRES_RENDER_SENTINEL='docker.io/artifacthub/postgres@sha256:411febeab51f103cd36aa8655bebb3c4035974e0d6f6929a56fe863ad8c581b6'
POSTGRES_RUNTIME_IMAGE="${AACHEN_PREVIEW_POSTGRES_IMAGE:?AACHEN_PREVIEW_POSTGRES_IMAGE is required}"
KUBECTL_PIN='docker.io/bitnamilegacy/kubectl@sha256:cd354d5b25562b195b277125439c23e4046902d7f1abc0dc3c75aad04d298c17'

tmp_in="$(mktemp)"
tmp_mid="$(mktemp)"
tmp_out="$(mktemp)"
cleanup() { rm -f "$tmp_in" "$tmp_mid" "$tmp_out"; }
trap cleanup EXIT INT TERM

cat > "$tmp_in"
sed \
  -e "s#$POSTGRES_RENDER_SENTINEL#$POSTGRES_RUNTIME_IMAGE#g" \
  -e "s#docker.io/artifacthub/postgres:latest#$POSTGRES_RUNTIME_IMAGE#g" \
  -e "s#docker.io/bitnamilegacy/kubectl:1.33#$KUBECTL_PIN#g" \
  "$tmp_in" > "$tmp_mid"

if ! awk -v image="$POSTGRES_RUNTIME_IMAGE" '
  /^[[:space:]]*image:/ && index($0, image) {
    preview_image = 1
    print
    next
  }
  preview_image && /^[[:space:]]*imagePullPolicy:/ {
    prefix = $0
    sub(/imagePullPolicy:.*/, "", prefix)
    print prefix "imagePullPolicy: Never"
    preview_image = 0
    next
  }
  preview_image && /^[[:space:]]*image:/ { exit 42 }
  { print }
  END { if (preview_image) exit 43 }
' "$tmp_mid" > "$tmp_out"; then
  echo 'Preview post-renderer: could not pin the local PostgreSQL image.' >&2
  exit 1
fi

# External login remains disabled for the private preview. This mirrors the
# reviewed Aachen private-runtime adapter without changing upstream OCG code.
python3 - "$tmp_out" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)

for marker in ("        github: false", "        linuxfoundation: false"):
    if sum(line.rstrip("\r\n") == marker for line in lines) != 1:
        raise SystemExit(f"Preview post-renderer: expected disabled login marker: {marker.strip()}")

def replace_mapping(key: str) -> None:
    needle = f"      {key}:"
    starts = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == needle]
    if len(starts) != 1:
        raise SystemExit(f"Preview post-renderer: expected one server {key} mapping")
    start = starts[0]
    end = start + 1
    while end < len(lines):
        raw = lines[end].rstrip("\r\n")
        if raw:
            indent = len(raw) - len(raw.lstrip(" "))
            if indent <= 6:
                break
        end += 1
    lines[start:end] = [f"      {key}: {{}}\n"]

replace_mapping("oauth2")
replace_mapping("oidc")
path.write_text("".join(lines), encoding="utf-8")
PY

if grep -Fq 'artifacthub/postgres' "$tmp_out"; then
  echo 'Preview post-renderer: external PostgreSQL image survived rendering.' >&2
  exit 1
fi
if grep -Eq 'docker.io/(library/)?postgres(:|@)' "$tmp_out"; then
  echo 'Preview post-renderer: Docker PostgreSQL image survived rendering.' >&2
  exit 1
fi
if grep -Eq 'docker.io/bitnamilegacy/kubectl:[^[:space:]\"]+' "$tmp_out"; then
  echo 'Preview post-renderer: mutable kubectl helper image survived rendering.' >&2
  exit 1
fi

grep -Fq "$POSTGRES_RUNTIME_IMAGE" "$tmp_out" || {
  echo 'Preview post-renderer: preview PostgreSQL image is missing.' >&2
  exit 1
}

cat "$tmp_out"

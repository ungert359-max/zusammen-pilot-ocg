#!/usr/bin/env bash
set -Eeuo pipefail

# Isolated synthetic product-E2E preparation for the Aachen pilot.
# This script never enables public ingress, real email, payments, or real user data.
# It prepares a dedicated namespace using the already verified private smoke path,
# then loads only the committed synthetic OCG E2E fixtures.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE_SCRIPT="$REPO_ROOT/pilot/aachen/private-smoke-test.sh"
SEED_SQL="$REPO_ROOT/database/tests/data/e2e.sql"
PRIVATE_VALUES_FILE="${AACHEN_PRIVATE_VALUES_FILE:-}"
NAMESPACE="${AACHEN_E2E_NAMESPACE:-ocg-aachen-e2e}"
RELEASE="${AACHEN_E2E_RELEASE:-aachen-e2e}"
LOCAL_PORT="${AACHEN_E2E_LOCAL_PORT:-19000}"
TIMEOUT="${AACHEN_E2E_TIMEOUT:-12m}"
MODE="${1:-prepare}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

require_dedicated_identity() {
  case "$NAMESPACE" in
    ocg-aachen-e2e|ocg-aachen-e2e-*) ;;
    *) fail "E2E namespace must be dedicated to Aachen synthetic E2E (found: $NAMESPACE)" ;;
  esac
  case "$NAMESPACE" in
    ocg-aachen-smoke|default|kube-*) fail "refusing to use a protected/shared namespace: $NAMESPACE" ;;
  esac

  case "$RELEASE" in
    aachen-e2e|aachen-e2e-*) ;;
    *) fail "E2E release must be dedicated to Aachen synthetic E2E (found: $RELEASE)" ;;
  esac
  [[ "$RELEASE" != "aachen-smoke" ]] || fail "refusing to reuse the known-good smoke release"
}

cleanup_namespace() {
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    info "Removing dedicated synthetic E2E namespace..."
    kubectl delete namespace "$NAMESPACE" --wait=true --timeout=180s >/dev/null
  fi
}

for command_name in bash kubectl python3 grep stat; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

require_dedicated_identity

case "$MODE" in
  cleanup)
    cleanup_namespace
    info "PASS: dedicated Aachen synthetic E2E namespace removed."
    exit 0
    ;;
  prepare) ;;
  *) fail "usage: $0 [prepare|cleanup]" ;;
esac

[[ -f "$SMOKE_SCRIPT" ]] || fail "private smoke script is missing"
[[ -f "$SEED_SQL" ]] || fail "committed synthetic E2E seed SQL is missing"
bash -n "$SMOKE_SCRIPT" || fail "private smoke script has invalid shell syntax"

[[ -n "$PRIVATE_VALUES_FILE" ]] || fail "AACHEN_PRIVATE_VALUES_FILE is required"
[[ -f "$PRIVATE_VALUES_FILE" ]] || fail "private values file does not exist"

private_real="$(readlink -f "$PRIVATE_VALUES_FILE")"
repo_real="$(readlink -f "$REPO_ROOT")"
case "$private_real" in
  "$repo_real"/*) fail "private values file must remain outside the Git repository" ;;
esac

private_mode="$(stat -c '%a' "$PRIVATE_VALUES_FILE")"
case "$private_mode" in
  400|600) ;;
  *) fail "private values file permissions must be 400 or 600 (current: $private_mode)" ;;
esac

# The fixture preparation is destructive only inside the dedicated synthetic
# E2E namespace. Delete any interrupted prior run so each attempt starts from
# a fresh database and cannot contaminate the known-good smoke release.
cleanup_namespace

info "Installing isolated private Aachen runtime for synthetic product E2E..."
AACHEN_NAMESPACE="$NAMESPACE" \
AACHEN_RELEASE="$RELEASE" \
AACHEN_LOCAL_PORT="$LOCAL_PORT" \
AACHEN_PRIVATE_VALUES_FILE="$PRIVATE_VALUES_FILE" \
AACHEN_TIMEOUT="$TIMEOUT" \
bash "$SMOKE_SCRIPT"

postgres_pod="$(
  kubectl -n "$NAMESPACE" get pods -o json |
    python3 -c '
import json
import sys

data = json.load(sys.stdin)
matches = []
for item in data.get("items", []):
    images = [c.get("image", "") for c in item.get("spec", {}).get("containers", [])]
    if "zusammen-pilot-postgres:local" in images:
        matches.append(item.get("metadata", {}).get("name", ""))

matches = [name for name in matches if name]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one local pilot PostgreSQL pod, found {len(matches)}")
print(matches[0])
'
)"
[[ -n "$postgres_pod" ]] || fail "could not identify the isolated PostgreSQL pod"

db_password="$(
  python3 - "$PRIVATE_VALUES_FILE" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
in_db = False

for line in lines:
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if not line[0].isspace():
        in_db = bool(re.fullmatch(r"db:\s*(?:#.*)?", line))
        continue
    if in_db:
        match = re.match(r'^\s+password:\s*(["\']?)(.*?)\1\s*(?:#.*)?$', line)
        if match and match.group(2):
            print(match.group(2))
            raise SystemExit(0)

raise SystemExit("private values do not contain a non-empty db.password")
PY
)"
[[ -n "$db_password" ]] || fail "database password could not be resolved from private values"

# Load only the repository's committed synthetic fixtures. Suppress normal psql
# output so the log contains neither private values nor a dump of fixture data.
info "Loading committed synthetic OCG E2E fixtures into the isolated database..."
kubectl -n "$NAMESPACE" exec -i "$postgres_pod" -- \
  env PGPASSWORD="$db_password" \
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U ocg -d ocg \
  < "$SEED_SQL" >/dev/null

# Match the public Playwright fixture credentials without printing credentials or
# hashes to the workflow log.
kubectl -n "$NAMESPACE" exec "$postgres_pod" -- \
  env PGPASSWORD="$db_password" \
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U ocg -d ocg -qAt \
  -c 'update "user" set password = $$$argon2id$v=19$m=19456,t=2,p=1$q55jlxUx8bffhFM3xN36ZA$te6OiWkZ/q35lpSEAZbd/A3iJyCByxbive9F61sTp7g$$ where username like $$e2e-%$$' \
  >/dev/null

synthetic_user_count="$(
  kubectl -n "$NAMESPACE" exec "$postgres_pod" -- \
    env PGPASSWORD="$db_password" \
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U ocg -d ocg -qAt \
    -c 'select count(*) from "user" where username like $$e2e-%$$'
)"
[[ "$synthetic_user_count" =~ ^[0-9]+$ ]] || fail "synthetic-user verification did not return a count"
(( synthetic_user_count >= 8 )) || fail "synthetic E2E users were not loaded as expected"

required_event_count="$(
  kubectl -n "$NAMESPACE" exec "$postgres_pod" -- \
    env PGPASSWORD="$db_password" \
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U ocg -d ocg -qAt \
    -c "select count(*) from event where event_id in (
      '55555555-5555-5555-5555-555555555501',
      '55555555-5555-5555-5555-555555555521',
      '55555555-5555-5555-5555-555555555529'
    )"
)"
[[ "$required_event_count" == "3" ]] || fail "required synthetic event fixtures are incomplete"

server_service="$(
  kubectl -n "$NAMESPACE" get service \
    -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$RELEASE" \
    -o name
)"
[[ -n "$server_service" ]] || fail "isolated server service was not created"
[[ "$(printf '%s\n' "$server_service" | wc -l)" -eq 1 ]] || fail "expected exactly one isolated server service"
[[ "$(kubectl -n "$NAMESPACE" get "$server_service" -o jsonpath='{.spec.type}')" == "ClusterIP" ]] ||
  fail "isolated server service is not private ClusterIP"

if [[ -n "$(kubectl -n "$NAMESPACE" get ingress -l "app.kubernetes.io/instance=$RELEASE" -o name 2>/dev/null)" ]]; then
  fail "synthetic E2E release unexpectedly exposes an Ingress"
fi

info "PASS: isolated private runtime is healthy and synthetic E2E fixtures are ready."
info "NEXT: run the selected upstream Playwright product journey through a loopback-only SSH tunnel, then invoke '$0 cleanup'."

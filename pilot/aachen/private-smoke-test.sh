#!/usr/bin/env bash
set -Eeuo pipefail

# Private, fail-closed runtime smoke test for the Aachen pilot.
# This script intentionally does not create or print deployment secrets.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART_SOURCE="$REPO_ROOT/charts/ocg"
PILOT_VALUES="$REPO_ROOT/pilot/aachen/values-pilot.yaml"
NAMESPACE="${AACHEN_NAMESPACE:-ocg-aachen-smoke}"
RELEASE="${AACHEN_RELEASE:-aachen-smoke}"
LOCAL_PORT="${AACHEN_LOCAL_PORT:-18080}"
PRIVATE_VALUES_FILE="${AACHEN_PRIVATE_VALUES_FILE:-}"
TIMEOUT="${AACHEN_TIMEOUT:-10m}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

for command_name in helm kubectl curl k3s grep awk sed stat mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

[[ -n "$PRIVATE_VALUES_FILE" ]] || fail "set AACHEN_PRIVATE_VALUES_FILE to a private Helm values file outside this repository"
[[ -f "$PRIVATE_VALUES_FILE" ]] || fail "private values file does not exist"

private_real="$(readlink -f "$PRIVATE_VALUES_FILE")"
repo_real="$(readlink -f "$REPO_ROOT")"
case "$private_real" in
  "$repo_real"/*) fail "private values file must be stored outside the Git repository" ;;
esac

private_mode="$(stat -c '%a' "$PRIVATE_VALUES_FILE")"
case "$private_mode" in
  400|600) ;;
  *) fail "private values file permissions must be 400 or 600 (current: $private_mode)" ;;
esac

# Kubernetes Secrets contain the database password and badge signing key. Do not
# write them to the k3s datastore unless encryption at rest is actually enabled.
secrets_status="$(k3s secrets-encrypt status 2>&1 || true)"
printf '%s\n' "$secrets_status" | grep -q 'Encryption Status: Enabled' || \
  fail "k3s secrets encryption at rest is not confirmed as Enabled"

kubectl cluster-info >/dev/null

# The pilot deliberately uses images already built and imported on this host.
for image_name in zusammen-pilot-server:local zusammen-pilot-dbmigrator:local; do
  k3s ctr images list | grep -Fq "$image_name" || fail "required k3s image is missing: $image_name"
done

tmpdir="$(mktemp -d)"
port_forward_pid=""
cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" >/dev/null 2>&1 || true
    wait "$port_forward_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM
chmod 700 "$tmpdir"

# Work from a temporary chart copy so dependency resolution cannot dirty the
# checked-out repository or silently replace committed upstream artifacts.
cp -a "$CHART_SOURCE" "$tmpdir/ocg"
rm -rf "$tmpdir/ocg/charts"
helm dependency build "$tmpdir/ocg" >/dev/null

rendered="$tmpdir/rendered.yaml"
umask 077
helm template "$RELEASE" "$tmpdir/ocg" \
  --namespace "$NAMESPACE" \
  -f "$PILOT_VALUES" \
  -f "$PRIVATE_VALUES_FILE" \
  > "$rendered"
chmod 600 "$rendered"

# Fail closed if deployment-time values fall back to the upstream development
# password or accidentally re-enable public exposure.
if grep -Eq '^[[:space:]]*password:[[:space:]]*ocg[[:space:]]*$|^[[:space:]]*password[[:space:]]*=[[:space:]]*ocg[[:space:]]*$' "$rendered"; then
  fail "rendered manifests still contain the upstream default database password"
fi
if grep -q '^kind: Ingress$' "$rendered"; then
  fail "rendered smoke-test manifests contain an Ingress"
fi

info "Installing private Aachen smoke-test release..."
helm upgrade --install "$RELEASE" "$tmpdir/ocg" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "$PILOT_VALUES" \
  -f "$PRIVATE_VALUES_FILE" \
  --wait \
  --wait-for-jobs \
  --atomic \
  --timeout "$TIMEOUT"

server_service="$(kubectl -n "$NAMESPACE" get service \
  -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$RELEASE" \
  -o name)"
[[ -n "$server_service" ]] || fail "server service was not created"
[[ "$(printf '%s\n' "$server_service" | wc -l)" -eq 1 ]] || fail "expected exactly one server service"

service_type="$(kubectl -n "$NAMESPACE" get "$server_service" -o jsonpath='{.spec.type}')"
[[ "$service_type" == "ClusterIP" ]] || fail "server service is not private ClusterIP (found: $service_type)"

if [[ -n "$(kubectl -n "$NAMESPACE" get ingress -l "app.kubernetes.io/instance=$RELEASE" -o name 2>/dev/null)" ]]; then
  fail "an Ingress exists for the private smoke-test release"
fi

kubectl -n "$NAMESPACE" wait --for=condition=complete job/dbmigrator-install --timeout=300s

server_deployment="$(kubectl -n "$NAMESPACE" get deployment \
  -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$RELEASE" \
  -o name)"
[[ -n "$server_deployment" ]] || fail "server deployment was not created"
[[ "$(printf '%s\n' "$server_deployment" | wc -l)" -eq 1 ]] || fail "expected exactly one server deployment"
kubectl -n "$NAMESPACE" rollout status "$server_deployment" --timeout=300s

kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 "$server_service" "$LOCAL_PORT:80" \
  >"$tmpdir/port-forward.log" 2>&1 &
port_forward_pid="$!"

health_ok=false
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:$LOCAL_PORT/health-check" >/dev/null; then
    health_ok=true
    break
  fi
  sleep 2
done
[[ "$health_ok" == true ]] || fail "OCG /health-check did not become healthy through local-only port-forward"

info "PASS: PostgreSQL/migration/server startup and /health-check succeeded without public Ingress."
info "Runtime resource snapshot (measurement only; not a minimum-capacity proof):"
kubectl -n "$NAMESPACE" get pods,pvc -o wide
if ! kubectl -n "$NAMESPACE" top pods; then
  info "NOT_VERIFIED: metrics-server resource snapshot unavailable."
fi

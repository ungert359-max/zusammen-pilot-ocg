#!/usr/bin/env bash
set -Eeuo pipefail

# Private, fail-closed runtime smoke test for the Aachen pilot.
# This script intentionally does not create or print deployment secrets.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART_SOURCE="$REPO_ROOT/charts/ocg"
PILOT_VALUES="$REPO_ROOT/pilot/aachen/values-pilot.yaml"
POST_RENDERER_SOURCE="$REPO_ROOT/pilot/aachen/pin-runtime-images.sh"
NAMESPACE="${AACHEN_NAMESPACE:-ocg-aachen-smoke}"
RELEASE="${AACHEN_RELEASE:-aachen-smoke}"
LOCAL_PORT="${AACHEN_LOCAL_PORT:-18080}"
PRIVATE_VALUES_FILE="${AACHEN_PRIVATE_VALUES_FILE:-}"
TIMEOUT="${AACHEN_TIMEOUT:-10m}"
POSTGRES_DIGEST="sha256:411febeab51f103cd36aa8655bebb3c4035974e0d6f6929a56fe863ad8c581b6"
KUBECTL_DIGEST="sha256:cd354d5b25562b195b277125439c23e4046902d7f1abc0dc3c75aad04d298c17"
BOOTSTRAP_SECRET_NAME="dbmigrator-config"

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

[[ -f "$POST_RENDERER_SOURCE" ]] || fail "Aachen runtime post-renderer is missing"
bash -n "$POST_RENDERER_SOURCE" || fail "Aachen runtime post-renderer has invalid shell syntax"

# The pilot's pinned PostgreSQL digest is the verified linux/amd64 image.
[[ "$(uname -m)" == "x86_64" ]] || fail "this smoke-test profile is pinned for linux/amd64 (x86_64)"

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
grep -q 'Encryption Status: Enabled' <<<"$secrets_status" || \
  fail "k3s secrets encryption at rest is not confirmed as Enabled"

kubectl cluster-info >/dev/null

# The pilot deliberately uses images already built and imported on this host.
# Capture the list once: with `set -o pipefail`, piping a long `ctr images list`
# directly into `grep -q` can turn a successful match into a false failure if
# grep exits early and ctr receives SIGPIPE.
images_list="$(k3s ctr images list)"
for image_name in zusammen-pilot-server:local zusammen-pilot-dbmigrator:local; do
  grep -Fq "$image_name" <<<"$images_list" || fail "required k3s image is missing: $image_name"
done

tmpdir="$(mktemp -d)"
port_forward_pid=""
bootstrap_secret_created=false
cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" >/dev/null 2>&1 || true
    wait "$port_forward_pid" >/dev/null 2>&1 || true
  fi
  if [[ "$bootstrap_secret_created" == true ]]; then
    kubectl -n "$NAMESPACE" delete secret "$BOOTSTRAP_SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
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

# The post-renderer is an additive pilot adapter. Copy it into the private temp
# directory and make only that copy executable so the Git checkout stays clean.
post_renderer="$tmpdir/pin-runtime-images.sh"
cp "$POST_RENDERER_SOURCE" "$post_renderer"
chmod 700 "$post_renderer"

rendered="$tmpdir/rendered.yaml"
umask 077
helm template "$RELEASE" "$tmpdir/ocg" \
  --namespace "$NAMESPACE" \
  -f "$PILOT_VALUES" \
  -f "$PRIVATE_VALUES_FILE" \
  --post-renderer "$post_renderer" \
  > "$rendered"
chmod 600 "$rendered"

# Fail closed if deployment-time values fall back to the upstream development
# password, if install-time helper images remain mutable, or if public exposure
# reappears.
if grep -Eq '^[[:space:]]*password:[[:space:]]*ocg[[:space:]]*$|^[[:space:]]*password[[:space:]]*=[[:space:]]*ocg[[:space:]]*$' "$rendered"; then
  fail "rendered manifests still contain the upstream default database password"
fi
grep -Fq "$POSTGRES_DIGEST" "$rendered" || fail "rendered PostgreSQL image is not pinned to the reviewed digest"
grep -Fq "$KUBECTL_DIGEST" "$rendered" || fail "rendered kubectl helper image is not pinned to the reviewed digest"
if grep -Fq 'docker.io/artifacthub/postgres:latest' "$rendered"; then
  fail "rendered manifests still contain a mutable PostgreSQL helper image"
fi
if grep -Eq 'docker.io/bitnamilegacy/kubectl:[^[:space:]\"]+' "$rendered"; then
  fail "rendered manifests still contain a mutable kubectl helper image"
fi
if grep -q '^kind: Ingress$' "$rendered"; then
  fail "rendered smoke-test manifests contain an Ingress"
fi
if grep -Eq '^[[:space:]]*type:[[:space:]]*(NodePort|LoadBalancer)[[:space:]]*$' "$rendered"; then
  fail "rendered smoke-test manifests contain a NodePort or LoadBalancer service"
fi
if grep -Eq '^[[:space:]]*externalIPs:[[:space:]]*' "$rendered"; then
  fail "rendered smoke-test manifests configure external service IPs"
fi
if grep -Eq '^[[:space:]]*hostNetwork:[[:space:]]*true[[:space:]]*$|^[[:space:]]*hostPort:[[:space:]]*[0-9]+' "$rendered"; then
  fail "rendered smoke-test manifests expose a pod through host networking or hostPort"
fi

# The inherited chart marks dbmigrator-config only as a pre-upgrade hook, while
# its normal install Job already needs that Secret. Helm 3 does not send hooks to
# executable post-renderers, so bootstrap exactly that existing Secret template
# before the first install instead of editing inherited chart code. The Secret is
# removed by cleanup after the migration has finished. Refuse upgrades here until
# the Helm 3 hook-image path has its own immutable-image gate.
if helm status "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  fail "upgrade smoke path is not yet verified with immutable hook helper images"
fi
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl create namespace "$NAMESPACE" >/dev/null
fi
helm template "$RELEASE" "$tmpdir/ocg" \
  --namespace "$NAMESPACE" \
  -f "$PILOT_VALUES" \
  -f "$PRIVATE_VALUES_FILE" \
  --show-only templates/db_migrator_secret.yaml \
  | kubectl -n "$NAMESPACE" apply -f - >/dev/null
bootstrap_secret_created=true
kubectl -n "$NAMESPACE" get secret "$BOOTSTRAP_SECRET_NAME" >/dev/null

info "Installing private Aachen smoke-test release..."
helm upgrade --install "$RELEASE" "$tmpdir/ocg" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "$PILOT_VALUES" \
  -f "$PRIVATE_VALUES_FILE" \
  --post-renderer "$post_renderer" \
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

# helm --wait --wait-for-jobs gates the install migration Job. Future upgrades
# remain intentionally blocked above until their hook-only helper image is also
# immutable under Helm 3.

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

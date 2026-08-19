#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHART_SOURCE="$REPO_ROOT/charts/ocg"
PILOT_VALUES="$REPO_ROOT/pilot/aachen/values-pilot.yaml"
POST_RENDERER_SOURCE="$REPO_ROOT/pilot/aachen/preview/pin-preview-images.sh"

NAMESPACE="${AACHEN_PREVIEW_NAMESPACE:?AACHEN_PREVIEW_NAMESPACE is required}"
RELEASE="${AACHEN_PREVIEW_RELEASE:?AACHEN_PREVIEW_RELEASE is required}"
PRIVATE_VALUES_FILE="${AACHEN_PREVIEW_PRIVATE_VALUES_FILE:?AACHEN_PREVIEW_PRIVATE_VALUES_FILE is required}"
SERVER_REPO="${AACHEN_PREVIEW_SERVER_REPO:?AACHEN_PREVIEW_SERVER_REPO is required}"
MIGRATOR_REPO="${AACHEN_PREVIEW_MIGRATOR_REPO:?AACHEN_PREVIEW_MIGRATOR_REPO is required}"
POSTGRES_IMAGE="${AACHEN_PREVIEW_POSTGRES_IMAGE:?AACHEN_PREVIEW_POSTGRES_IMAGE is required}"
LOCAL_PORT="${AACHEN_PREVIEW_LOCAL_PORT:-18081}"
TIMEOUT="${AACHEN_PREVIEW_TIMEOUT:-12m}"
BOOTSTRAP_SECRET_NAME=dbmigrator-config

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

for c in helm kubectl curl k3s grep awk stat mktemp python3; do
  command -v "$c" >/dev/null 2>&1 || fail "required command not found: $c"
done
[[ -f "$PRIVATE_VALUES_FILE" ]] || fail "private preview values file missing"
[[ "$(stat -c '%a' "$PRIVATE_VALUES_FILE")" =~ ^(400|600)$ ]] || fail "private preview values permissions must be 400 or 600"
k3s secrets-encrypt status | grep -q 'Encryption Status: Enabled' || fail "k3s secrets encryption is not enabled"

# The preview must use only its unique image names. Never accept the verified
# runtime tags here because that could make a later pod restart pick up preview code.
case "$SERVER_REPO" in zusammen-preview-server-*) ;; *) fail "server repo is not preview-isolated" ;; esac
case "$MIGRATOR_REPO" in zusammen-preview-dbmigrator-*) ;; *) fail "migrator repo is not preview-isolated" ;; esac
case "$POSTGRES_IMAGE" in zusammen-preview-postgres-*:local) ;; *) fail "postgres image is not preview-isolated" ;; esac

images_list="$(k3s ctr images list)"
grep -Fq "$SERVER_REPO:local" <<<"$images_list" || fail "preview server image missing"
grep -Fq "$MIGRATOR_REPO:local" <<<"$images_list" || fail "preview migrator image missing"
grep -Fq "$POSTGRES_IMAGE" <<<"$images_list" || fail "preview postgres image missing"

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

cp -a "$CHART_SOURCE" "$tmpdir/ocg"
rm -rf "$tmpdir/ocg/charts"
helm dependency build "$tmpdir/ocg" >/dev/null
post_renderer="$tmpdir/pin-preview-images.sh"
cp "$POST_RENDERER_SOURCE" "$post_renderer"
chmod 700 "$post_renderer"
export AACHEN_PREVIEW_POSTGRES_IMAGE="$POSTGRES_IMAGE"

rendered="$tmpdir/rendered.yaml"
umask 077
helm template "$RELEASE" "$tmpdir/ocg" \
  --namespace "$NAMESPACE" \
  -f "$PILOT_VALUES" \
  -f "$PRIVATE_VALUES_FILE" \
  --set-string "server.deploy.image.repository=$SERVER_REPO" \
  --set-string "dbmigrator.job.image.repository=$MIGRATOR_REPO" \
  --post-renderer "$post_renderer" \
  > "$rendered"
chmod 600 "$rendered"

# Fail closed: this preview is private, payment-off and image-isolated.
grep -Fq 'payments: null' "$rendered" || fail "preview rendered with payments enabled"
if grep -Eq '^[[:space:]]+(publishable_key|secret_key|webhook_secret):' "$rendered"; then
  fail "payment provider credentials appeared in preview render"
fi
if grep -q '^kind: Ingress$' "$rendered"; then fail "preview render contains Ingress"; fi
if grep -Eq '^[[:space:]]*type:[[:space:]]*(NodePort|LoadBalancer)[[:space:]]*$' "$rendered"; then
  fail "preview render contains public service type"
fi
grep -Fq "$SERVER_REPO:local" "$rendered" || fail "preview server image not rendered"
grep -Fq "$MIGRATOR_REPO:local" "$rendered" || fail "preview migrator image not rendered"
grep -Fq "$POSTGRES_IMAGE" "$rendered" || fail "preview postgres image not rendered"
if grep -Fq 'zusammen-pilot-server:local' "$rendered" || grep -Fq 'zusammen-pilot-dbmigrator:local' "$rendered" || grep -Fq 'zusammen-pilot-postgres:local' "$rendered"; then
  fail "verified runtime image tag leaked into preview render"
fi

# Never reuse or delete the verified runtime namespace/release.
[[ "$NAMESPACE" != "ocg-aachen-smoke" ]] || fail "preview may not use verified smoke namespace"
[[ "$RELEASE" != "aachen-smoke" ]] || fail "preview may not use verified smoke release"

# Replace only the dedicated preview release if this exact preview is re-run.
if helm status "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  helm uninstall "$RELEASE" --namespace "$NAMESPACE" --wait --timeout 2m >/dev/null
fi
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl create namespace "$NAMESPACE" >/dev/null
fi

helm template "$RELEASE" "$tmpdir/ocg" \
  --namespace "$NAMESPACE" \
  -f "$PILOT_VALUES" \
  -f "$PRIVATE_VALUES_FILE" \
  --set-string "server.deploy.image.repository=$SERVER_REPO" \
  --set-string "dbmigrator.job.image.repository=$MIGRATOR_REPO" \
  --show-only templates/db_migrator_secret.yaml \
  | kubectl -n "$NAMESPACE" apply -f - >/dev/null
bootstrap_secret_created=true

info "Installing isolated Aachen preview..."
helm upgrade --install "$RELEASE" "$tmpdir/ocg" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "$PILOT_VALUES" \
  -f "$PRIVATE_VALUES_FILE" \
  --set-string "server.deploy.image.repository=$SERVER_REPO" \
  --set-string "dbmigrator.job.image.repository=$MIGRATOR_REPO" \
  --post-renderer "$post_renderer" \
  --wait --wait-for-jobs --timeout "$TIMEOUT"

server_service="$(kubectl -n "$NAMESPACE" get service \
  -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$RELEASE" \
  -o name)"
[[ -n "$server_service" ]] || fail "preview server service missing"
[[ "$(kubectl -n "$NAMESPACE" get "$server_service" -o jsonpath='{.spec.type}')" == ClusterIP ]] || fail "preview service is not ClusterIP"

kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 "$server_service" "$LOCAL_PORT:80" >"$tmpdir/port-forward.log" 2>&1 &
port_forward_pid="$!"
health_ok=false
for _ in $(seq 1 45); do
  if curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:$LOCAL_PORT/health-check" >/dev/null; then
    health_ok=true
    break
  fi
  sleep 2
done
[[ "$health_ok" == true ]] || fail "preview health-check did not become green"

info "PASS: isolated Aachen preview is healthy."
info "PREVIEW_NAMESPACE=$NAMESPACE"
info "PREVIEW_RELEASE=$RELEASE"
info "PREVIEW_SERVICE=$server_service"
kubectl -n "$NAMESPACE" get pods,svc,pvc -o wide

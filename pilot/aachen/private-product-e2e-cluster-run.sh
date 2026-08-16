#!/usr/bin/env bash
set -Eeuo pipefail

# Runs the unchanged upstream OCG Playwright suite next to the isolated private
# Aachen runtime. The browser runner is an ephemeral Kubernetes pod in the same
# dedicated namespace, so product verification does not depend on the slower
# GitHub -> SSH -> kubectl port-forward transport. No OCG application source is
# modified. The runner pod has no service-account token and is removed on exit.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_DIR="$REPO_ROOT/tests/e2e"
NAMESPACE="${AACHEN_E2E_NAMESPACE:-ocg-aachen-e2e}"
RELEASE="${AACHEN_E2E_RELEASE:-aachen-e2e}"
RUN_FULL_SUITE="${AACHEN_E2E_RUN_FULL_SUITE:-true}"
RUNNER_POD="${AACHEN_E2E_RUNNER_POD:-aachen-e2e-playwright}"
PLAYWRIGHT_IMAGE="${AACHEN_E2E_PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright@sha256:5b8f294aff9041b7191c34a4bab3ac270157a28774d4b0660e9743297b697e48}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

for command_name in bash kubectl grep; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

case "$NAMESPACE" in
  ocg-aachen-e2e|ocg-aachen-e2e-*) ;;
  *) fail "runner requires a dedicated Aachen synthetic E2E namespace (found: $NAMESPACE)" ;;
esac
case "$RELEASE" in
  aachen-e2e|aachen-e2e-*) ;;
  *) fail "runner requires a dedicated Aachen synthetic E2E release (found: $RELEASE)" ;;
esac
case "$RUN_FULL_SUITE" in
  true|false) ;;
  *) fail "AACHEN_E2E_RUN_FULL_SUITE must be true or false" ;;
esac
[[ "$RUNNER_POD" =~ ^aachen-e2e-playwright(-[a-z0-9-]+)?$ ]] || fail "unexpected E2E runner pod name"
[[ "$PLAYWRIGHT_IMAGE" == mcr.microsoft.com/playwright@sha256:* ]] || fail "Playwright image must be digest-pinned from mcr.microsoft.com/playwright"
[[ -d "$E2E_DIR" ]] || fail "upstream Playwright E2E directory is missing"
[[ -f "$E2E_DIR/package-lock.json" ]] || fail "pinned upstream E2E package-lock.json is missing"
[[ -f "$E2E_DIR/playwright.config.js" ]] || fail "upstream Playwright config is missing"

git_diff="$(git -C "$REPO_ROOT" status --porcelain -- tests/e2e || true)"
[[ -z "$git_diff" ]] || fail "refusing to run from a working tree with modified upstream E2E files"

service="$(kubectl -n "$NAMESPACE" get service \
  -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$RELEASE" \
  -o name)"
[[ -n "$service" ]] || fail "private E2E server service was not found"
[[ "$(printf '%s\n' "$service" | wc -l)" -eq 1 ]] || fail "expected exactly one private E2E server service"
[[ "$(kubectl -n "$NAMESPACE" get "$service" -o jsonpath='{.spec.type}')" == "ClusterIP" ]] || fail "private E2E service is not ClusterIP"
[[ -z "$(kubectl -n "$NAMESPACE" get ingress -l "app.kubernetes.io/instance=$RELEASE" -o name 2>/dev/null)" ]] || fail "public/private E2E ingress unexpectedly exists"
service_name="${service#service/}"

cleanup() {
  kubectl -n "$NAMESPACE" delete pod "$RUNNER_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

info "Creating digest-pinned private Playwright runner pod..."
cat <<EOF | kubectl -n "$NAMESPACE" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $RUNNER_POD
  labels:
    app.kubernetes.io/name: aachen-private-e2e-playwright
    app.kubernetes.io/instance: $RELEASE
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
    - name: runner
      image: $PLAYWRIGHT_IMAGE
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-lc", "sleep 14400"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: "250m"
          memory: "1Gi"
        limits:
          cpu: "2"
          memory: "3Gi"
      volumeMounts:
        - name: dshm
          mountPath: /dev/shm
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: "1Gi"
EOF

kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$RUNNER_POD" --timeout=8m >/dev/null

resolved_image="$(kubectl -n "$NAMESPACE" get pod "$RUNNER_POD" -o jsonpath='{.status.containerStatuses[0].imageID}')"
[[ "$resolved_image" == *"sha256:"* ]] || fail "Playwright runner image digest was not resolved"
info "PASS: private Playwright runner is ready with an immutable image reference."

kubectl -n "$NAMESPACE" exec "$RUNNER_POD" -- mkdir -p /work/e2e
kubectl -n "$NAMESPACE" cp "$E2E_DIR/." "$RUNNER_POD:/work/e2e" -c runner

# The test files copied above must remain byte-identical to the checked-out
# upstream suite. Generate a manifest on the host and verify it in the pod.
(
  cd "$E2E_DIR"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > /tmp/aachen-e2e-upstream.sha256
kubectl -n "$NAMESPACE" cp /tmp/aachen-e2e-upstream.sha256 "$RUNNER_POD:/work/upstream.sha256" -c runner
rm -f /tmp/aachen-e2e-upstream.sha256
kubectl -n "$NAMESPACE" exec "$RUNNER_POD" -- bash -lc 'cd /work/e2e && sha256sum -c /work/upstream.sha256 >/dev/null'
info "PASS: runner test sources are byte-identical to the checked-out upstream E2E suite."

kubectl -n "$NAMESPACE" exec "$RUNNER_POD" -- bash -lc 'cd /work/e2e && npm ci --ignore-scripts'

# Keep the browser-facing base URL identical to the upstream/private test
# contract (127.0.0.1:9000). A tiny in-pod TCP proxy forwards that loopback port
# to the private ClusterIP service; it performs no application transformations.
kubectl -n "$NAMESPACE" exec -i "$RUNNER_POD" -- bash -lc 'cat > /work/proxy.cjs' <<'NODE'
const net = require("node:net");
const targetHost = process.env.TARGET_HOST;
const targetPort = Number(process.env.TARGET_PORT || "80");
if (!targetHost || !Number.isInteger(targetPort)) process.exit(2);
const server = net.createServer((client) => {
  const upstream = net.connect({ host: targetHost, port: targetPort });
  client.pipe(upstream);
  upstream.pipe(client);
  const close = () => {
    client.destroy();
    upstream.destroy();
  };
  client.on("error", close);
  upstream.on("error", close);
});
server.listen(9000, "127.0.0.1");
NODE
kubectl -n "$NAMESPACE" exec "$RUNNER_POD" -- bash -lc \
  "TARGET_HOST='$service_name' TARGET_PORT=80 nohup node /work/proxy.cjs >/work/proxy.log 2>&1 &"

proxy_ready=false
for _ in $(seq 1 30); do
  if kubectl -n "$NAMESPACE" exec "$RUNNER_POD" -- node -e \
    'fetch("http://127.0.0.1:9000/health-check").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' \
    >/dev/null 2>&1; then
    proxy_ready=true
    break
  fi
  sleep 2
done
[[ "$proxy_ready" == true ]] || {
  kubectl -n "$NAMESPACE" exec "$RUNNER_POD" -- tail -n 40 /work/proxy.log >&2 || true
  fail "cluster-local browser proxy did not reach /health-check"
}
info "PASS: browser runner reaches the unchanged private OCG server through cluster-local loopback."

pw_env=(
  OCG_E2E_BASE_URL=http://127.0.0.1:9000
  OCG_E2E_START_SERVER=false
  OCG_E2E_REUSE_SERVER=false
  OCG_E2E_MEETINGS_ENABLED=false
  OCG_E2E_PAYMENTS_ENABLED=false
)

run_pw() {
  kubectl -n "$NAMESPACE" exec "$RUNNER_POD" -- env "${pw_env[@]}" bash -lc \
    "cd /work/e2e && npx playwright test --config playwright.config.js --timeout 120000 $*"
}

run_product_check() {
  local file="$1"
  local title="$2"
  info "Running unchanged upstream product check in private cluster: $title"
  run_pw "--project=chromium-deep '$file' --grep '$title'"
}

# First prove the four launch-critical journeys using the upstream test files
# without editing their helpers, assertions, timeouts or fixtures. The harness
# grants extra wall-clock budget for the containerized private runtime only.
run_product_check "workflows/events/events.spec.js" "organizer can create and delete an event"
run_product_check "workflows/rsvp/rsvp.spec.js" "approved RSVP requests are claimed through checkout"
run_product_check "workflows/waitlist/waitlist.spec.js" "a waitlisted user is promoted when the attendee leaves"
run_product_check "site/event/check-in.spec.js" "attendee can submit the public check-in form"
info "PASS: unchanged upstream event/RSVP/waitlist/check-in journeys passed cluster-locally."

if [[ "$RUN_FULL_SUITE" == true ]]; then
  info "Running complete upstream Smoke suite against the private runtime..."
  run_pw "--project=chromium-smoke --project=firefox-smoke --project=webkit-smoke"
  info "PASS: complete upstream Smoke suite passed."

  info "Running complete upstream Functional suite against the private runtime..."
  run_pw "--project=chromium-deep --project=chromium-mobile-deep"
  info "PASS: complete upstream Functional suite passed with payments/meetings integrations explicitly disabled."
fi

info "PASS: private cluster-local OCG product verification completed."

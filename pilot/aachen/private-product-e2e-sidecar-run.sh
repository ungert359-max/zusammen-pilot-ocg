#!/usr/bin/env bash
set -Eeuo pipefail

# Runs the unchanged upstream OCG Playwright suite in a test-only sidecar next
# to the exact private E2E server container. Both containers share the pod
# network namespace, so upstream's 127.0.0.1:9000 navigation contract is met
# without changing OCG source, upstream tests, assertions, helpers, or fixtures.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_DIR="$REPO_ROOT/tests/e2e"
NAMESPACE="${AACHEN_E2E_NAMESPACE:-ocg-aachen-e2e}"
RELEASE="${AACHEN_E2E_RELEASE:-aachen-e2e}"
RUN_FULL_SUITE="${AACHEN_E2E_RUN_FULL_SUITE:-true}"
RUNNER_CONTAINER="aachen-e2e-playwright"
PLAYWRIGHT_IMAGE="${AACHEN_E2E_PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright@sha256:5b8f294aff9041b7191c34a4bab3ac270157a28774d4b0660e9743297b697e48}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

for command_name in bash kubectl k3s grep find sort xargs sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

case "$NAMESPACE" in ocg-aachen-e2e|ocg-aachen-e2e-*) ;; *) fail "sidecar runner requires a dedicated Aachen E2E namespace" ;; esac
case "$RELEASE" in aachen-e2e|aachen-e2e-*) ;; *) fail "sidecar runner requires a dedicated Aachen E2E release" ;; esac
case "$RUN_FULL_SUITE" in true|false) ;; *) fail "AACHEN_E2E_RUN_FULL_SUITE must be true or false" ;; esac
[[ "$PLAYWRIGHT_IMAGE" == mcr.microsoft.com/playwright@sha256:* ]] || fail "Playwright image must be digest-pinned"
[[ -d "$E2E_DIR" && -f "$E2E_DIR/package-lock.json" && -f "$E2E_DIR/playwright.config.js" ]] || fail "upstream E2E tree is incomplete"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain -- tests/e2e || true)" ]] || fail "upstream E2E files are modified"

server_deployment="$(kubectl -n "$NAMESPACE" get deployment -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$RELEASE" -o name)"
[[ -n "$server_deployment" ]] || fail "private E2E server deployment was not found"
[[ "$(printf '%s\n' "$server_deployment" | wc -l)" -eq 1 ]] || fail "expected exactly one private E2E server deployment"

# Pull the large browser image before changing the already-healthy deployment.
# The previous two attempts spent the entire deployment progress window after
# adding this sidecar. Pre-pulling keeps the product runtime unchanged until the
# digest-pinned test image is definitely available on the single private node.
info "Pre-pulling digest-pinned Playwright sidecar image before deployment change..."
k3s ctr images pull "$PLAYWRIGHT_IMAGE" >/dev/null
info "PASS: digest-pinned Playwright sidecar image is present in private k3s."

# The prior cluster-local runner still inserted a TCP proxy/service hop. Logs
# proved the unchanged upstream helper's explicit 5s page.goto budget was then
# exceeded repeatedly. Add only a test companion container to the isolated
# deployment so Playwright talks to the unchanged server container over the
# shared pod loopback exactly as upstream expects.
info "Adding digest-pinned Playwright sidecar to the isolated E2E server deployment..."
kubectl -n "$NAMESPACE" patch "$server_deployment" --type=strategic -p "$(cat <<EOF
spec:
  template:
    spec:
      automountServiceAccountToken: false
      volumes:
        - name: aachen-e2e-dshm
          emptyDir:
            medium: Memory
            sizeLimit: 1Gi
      containers:
        - name: $RUNNER_CONTAINER
          image: $PLAYWRIGHT_IMAGE
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-lc", "sleep 14400"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 250m
              memory: 1Gi
            limits:
              cpu: "2"
              memory: 3Gi
          volumeMounts:
            - name: aachen-e2e-dshm
              mountPath: /dev/shm
EOF
)" >/dev/null
if ! kubectl -n "$NAMESPACE" rollout status "$server_deployment" --timeout=10m >/dev/null; then
  info "Sidecar rollout failed; collecting non-secret pod status and events."
  kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$RELEASE" -o wide >&2 || true
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp --field-selector involvedObject.kind=Pod 2>/dev/null | tail -n 40 >&2 || true
  fail "Playwright sidecar rollout did not become ready"
fi

server_pod="$(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$RELEASE" -o name)"
[[ -n "$server_pod" ]] || fail "server pod with sidecar was not created"
[[ "$(printf '%s\n' "$server_pod" | wc -l)" -eq 1 ]] || fail "expected exactly one server pod after sidecar rollout"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "$server_pod" --timeout=8m >/dev/null

resolved_runner_image="$(kubectl -n "$NAMESPACE" get "$server_pod" -o jsonpath="{.status.containerStatuses[?(@.name=='$RUNNER_CONTAINER')].imageID}")"
[[ "$resolved_runner_image" == *sha256:* ]] || fail "Playwright sidecar image digest was not resolved"

# Prove the browser companion reaches the actual server container over the same
# pod's loopback before copying or executing any tests.
kubectl -n "$NAMESPACE" exec "$server_pod" -c "$RUNNER_CONTAINER" -- node -e 'fetch("http://127.0.0.1:9000/health-check").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))'
info "PASS: Playwright sidecar reaches the unchanged private OCG server on same-pod loopback."

kubectl -n "$NAMESPACE" exec "$server_pod" -c "$RUNNER_CONTAINER" -- mkdir -p /work/e2e
kubectl -n "$NAMESPACE" cp "$E2E_DIR/." "${server_pod#pod/}:/work/e2e" -c "$RUNNER_CONTAINER"

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT INT TERM
(
  cd "$E2E_DIR"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$manifest"
kubectl -n "$NAMESPACE" cp "$manifest" "${server_pod#pod/}:/work/upstream.sha256" -c "$RUNNER_CONTAINER"
kubectl -n "$NAMESPACE" exec "$server_pod" -c "$RUNNER_CONTAINER" -- bash -lc 'cd /work/e2e && sha256sum -c /work/upstream.sha256 >/dev/null'
info "PASS: sidecar test sources are byte-identical to checked-out upstream E2E sources."

kubectl -n "$NAMESPACE" exec "$server_pod" -c "$RUNNER_CONTAINER" -- bash -lc 'cd /work/e2e && npm ci --ignore-scripts'

pw_env=(
  OCG_E2E_BASE_URL=http://127.0.0.1:9000
  OCG_E2E_START_SERVER=false
  OCG_E2E_REUSE_SERVER=false
  OCG_E2E_MEETINGS_ENABLED=false
  OCG_E2E_PAYMENTS_ENABLED=false
)

run_pw() {
  kubectl -n "$NAMESPACE" exec "$server_pod" -c "$RUNNER_CONTAINER" -- env "${pw_env[@]}" bash -lc \
    "cd /work/e2e && npx playwright test --config playwright.config.js --timeout 120000 $*"
}

run_product_check() {
  local file="$1"
  local title="$2"
  info "Running unchanged upstream product check on same-pod loopback: $title"
  run_pw "--project=chromium-deep '$file' --grep '$title'"
}

run_product_check "workflows/events/events.spec.js" "organizer can create and delete an event"
run_product_check "workflows/rsvp/rsvp.spec.js" "approved RSVP requests are claimed through checkout"
run_product_check "workflows/waitlist/waitlist.spec.js" "a waitlisted user is promoted when the attendee leaves"
run_product_check "site/event/check-in.spec.js" "attendee can submit the public check-in form"
info "PASS: unchanged upstream event/RSVP/waitlist/check-in journeys passed."

if [[ "$RUN_FULL_SUITE" == true ]]; then
  info "Running complete upstream Smoke suite against same-pod private runtime..."
  run_pw "--project=chromium-smoke --project=firefox-smoke --project=webkit-smoke"
  info "PASS: complete upstream Smoke suite passed."

  info "Running complete upstream Functional suite against same-pod private runtime..."
  run_pw "--project=chromium-deep --project=chromium-mobile-deep"
  info "PASS: complete upstream Functional suite passed with payments/meetings explicitly disabled."
fi

info "PASS: private same-pod OCG product verification completed."

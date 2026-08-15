#!/usr/bin/env bash
set -Eeuo pipefail

# Runs the selected upstream OCG product E2E checks against an already prepared
# isolated Aachen E2E namespace. The application remains private: the browser
# reaches it only through a loopback-only SSH tunnel and remote kubectl
# port-forward. This script never enables Ingress, public services, email, or
# payments and never reads the server's private Helm values.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_DIR="$REPO_ROOT/tests/e2e"
SSH_HOST="${AACHEN_E2E_SSH_HOST:-}"
SSH_USER="${AACHEN_E2E_SSH_USER:-deploy}"
SSH_KEY_FILE="${AACHEN_E2E_SSH_KEY_FILE:-}"
KNOWN_HOSTS_FILE="${AACHEN_E2E_KNOWN_HOSTS_FILE:-}"
NAMESPACE="${AACHEN_E2E_NAMESPACE:-ocg-aachen-e2e}"
RELEASE="${AACHEN_E2E_RELEASE:-aachen-e2e}"
LOCAL_PORT="${AACHEN_E2E_BROWSER_PORT:-9000}"
REMOTE_PORT="${AACHEN_E2E_REMOTE_PORT:-19000}"
KUBECONFIG_REMOTE="${AACHEN_E2E_REMOTE_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
INSTALL_BROWSER="${AACHEN_E2E_INSTALL_BROWSER:-true}"
TEST_TIMEOUT_MS="${AACHEN_E2E_TEST_TIMEOUT_MS:-120000}"

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

for command_name in bash curl npm node ssh grep stat readlink python3; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

require_dedicated_identity

[[ -d "$E2E_DIR" ]] || fail "upstream Playwright E2E directory is missing"
[[ -f "$E2E_DIR/package-lock.json" ]] || fail "pinned E2E package-lock.json is missing"
[[ -f "$E2E_DIR/playwright.config.js" ]] || fail "upstream Playwright config is missing"
[[ -n "$SSH_HOST" ]] || fail "AACHEN_E2E_SSH_HOST is required"
[[ -n "$SSH_KEY_FILE" ]] || fail "AACHEN_E2E_SSH_KEY_FILE is required"
[[ -n "$KNOWN_HOSTS_FILE" ]] || fail "AACHEN_E2E_KNOWN_HOSTS_FILE is required"
[[ -f "$SSH_KEY_FILE" ]] || fail "SSH private key file does not exist"
[[ -f "$KNOWN_HOSTS_FILE" ]] || fail "pinned known_hosts file does not exist"

repo_real="$(readlink -f "$REPO_ROOT")"
key_real="$(readlink -f "$SSH_KEY_FILE")"
case "$key_real" in
  "$repo_real"/*) fail "SSH private key must remain outside the Git repository" ;;
esac

key_mode="$(stat -c '%a' "$SSH_KEY_FILE")"
case "$key_mode" in
  400|600) ;;
  *) fail "SSH private key permissions must be 400 or 600 (current: $key_mode)" ;;
esac

[[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || fail "AACHEN_E2E_BROWSER_PORT must be numeric"
[[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || fail "AACHEN_E2E_REMOTE_PORT must be numeric"
[[ "$TEST_TIMEOUT_MS" =~ ^[0-9]+$ ]] || fail "AACHEN_E2E_TEST_TIMEOUT_MS must be numeric"
(( LOCAL_PORT >= 1024 && LOCAL_PORT <= 65535 )) || fail "browser tunnel port is outside the unprivileged TCP range"
(( REMOTE_PORT >= 1024 && REMOTE_PORT <= 65535 )) || fail "remote port-forward port is outside the unprivileged TCP range"
(( TEST_TIMEOUT_MS >= 30000 && TEST_TIMEOUT_MS <= 600000 )) || fail "AACHEN_E2E_TEST_TIMEOUT_MS must be between 30000 and 600000 milliseconds"
[[ "$LOCAL_PORT" == "9000" ]] || fail "current private pilot baseUrl is pinned to loopback port 9000; refusing a mismatched browser port"

node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
[[ "$node_major" =~ ^[0-9]+$ ]] || fail "could not determine Node.js major version"
(( node_major >= 22 )) || fail "upstream E2E requires Node.js 22 or newer"

ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE"
  -o ConnectTimeout=10
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=4
  -o ExitOnForwardFailure=yes
  -i "$SSH_KEY_FILE"
)

# First prove the remote release is the dedicated, private E2E deployment before
# establishing any tunnel. No Secret or ConfigMap content is read or printed.
ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
  "sudo -n env KUBECONFIG='$KUBECONFIG_REMOTE' bash -s -- '$NAMESPACE' '$RELEASE'" <<'REMOTE_PREFLIGHT'
set -Eeuo pipefail
namespace="$1"
release="$2"

command -v kubectl >/dev/null
command -v k3s >/dev/null
k3s secrets-encrypt status | grep -q 'Encryption Status: Enabled'

service="$(kubectl -n "$namespace" get service \
  -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$release" \
  -o name)"
[[ -n "$service" ]]
[[ "$(printf '%s\n' "$service" | wc -l)" -eq 1 ]]
[[ "$(kubectl -n "$namespace" get "$service" -o jsonpath='{.spec.type}')" == "ClusterIP" ]]
[[ -z "$(kubectl -n "$namespace" get ingress -l "app.kubernetes.io/instance=$release" -o name 2>/dev/null)" ]]
REMOTE_PREFLIGHT

scratch="$(mktemp -d)"
tunnel_pid=""
cleanup() {
  if [[ -n "$tunnel_pid" ]]; then
    kill "$tunnel_pid" >/dev/null 2>&1 || true
    wait "$tunnel_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM
chmod 700 "$scratch"

# The SSH session itself runs the remote kubectl port-forward. The local -L
# binds only 127.0.0.1, so neither the k3s ClusterIP nor the browser endpoint is
# exposed publicly. Remote service discovery is repeated inside the same
# session so no service name needs to cross the trust boundary.
ssh "${ssh_opts[@]}" \
  -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
  "$SSH_USER@$SSH_HOST" \
  "sudo -n env KUBECONFIG='$KUBECONFIG_REMOTE' bash -s -- '$NAMESPACE' '$RELEASE' '$REMOTE_PORT'" \
  >"$scratch/tunnel.log" 2>&1 <<'REMOTE_TUNNEL' &
set -Eeuo pipefail
namespace="$1"
release="$2"
remote_port="$3"
service="$(kubectl -n "$namespace" get service \
  -l "app.kubernetes.io/component=server,app.kubernetes.io/instance=$release" \
  -o name)"
[[ -n "$service" ]]
[[ "$(printf '%s\n' "$service" | wc -l)" -eq 1 ]]
exec kubectl -n "$namespace" port-forward --address 127.0.0.1 "$service" "$remote_port:80"
REMOTE_TUNNEL
tunnel_pid="$!"

health_ok=false
for _ in $(seq 1 45); do
  if ! kill -0 "$tunnel_pid" >/dev/null 2>&1; then
    info "SSH tunnel exited before the private health endpoint became ready."
    tail -n 40 "$scratch/tunnel.log" >&2 || true
    fail "loopback-only E2E tunnel failed"
  fi
  if curl --fail --silent --show-error --max-time 3 \
    "http://127.0.0.1:${LOCAL_PORT}/health-check" >/dev/null; then
    health_ok=true
    break
  fi
  sleep 2
done
[[ "$health_ok" == true ]] || fail "private E2E /health-check did not become reachable through the loopback-only tunnel"

info "PASS: dedicated private E2E runtime is reachable through loopback only."

cd "$E2E_DIR"

# The upstream attendance helper assumes a local server and can hold a stale
# sold-out event page indefinitely during cleanup. Keep the committed upstream
# test source untouched, but make the ephemeral runner copy re-load only while
# neither valid attendance state is visible. Product assertions are unchanged.
python3 - <<'PY'
from pathlib import Path

path = Path("utils.js")
text = path.read_text()
source = '''export const waitForAttendanceState = async (page) => {
  await Promise.race([
    getAttendButton(page).waitFor({ state: "visible" }),
    getLeaveButton(page).waitFor({ state: "visible" }),
  ]);
};'''
target = '''export const waitForAttendanceState = async (page) => {
  for (let attempt = 1; attempt <= 8; attempt += 1) {
    if ((await getAttendButton(page).isVisible()) || (await getLeaveButton(page).isVisible())) {
      return;
    }

    if (attempt < 8) {
      await page.waitForTimeout(2_000);
      await page.reload({ waitUntil: "domcontentloaded" });
    }
  }

  await Promise.race([
    getAttendButton(page).waitFor({ state: "visible", timeout: 30_000 }),
    getLeaveButton(page).waitFor({ state: "visible", timeout: 30_000 }),
  ]);
};'''
if text.count(source) != 1:
    raise SystemExit("expected exactly one upstream attendance-state helper")
path.write_text(text.replace(source, target))
PY
grep -Fq 'for (let attempt = 1; attempt <= 8; attempt += 1)' utils.js

npm ci --ignore-scripts

case "$INSTALL_BROWSER" in
  true) npx playwright install --with-deps chromium ;;
  false) ;;
  *) fail "AACHEN_E2E_INSTALL_BROWSER must be true or false" ;;
esac

export OCG_E2E_BASE_URL="http://127.0.0.1:${LOCAL_PORT}"
export OCG_E2E_START_SERVER=false
export OCG_E2E_REUSE_SERVER=false
export OCG_E2E_MEETINGS_ENABLED=false
export OCG_E2E_PAYMENTS_ENABLED=false

run_product_check() {
  local file="$1"
  local title="$2"
  info "Running synthetic upstream product check: $title"
  npx playwright test \
    --config playwright.config.js \
    --project=chromium-deep \
    --timeout "$TEST_TIMEOUT_MS" \
    "$file" \
    --grep "$title"
}

# Keep the first private product gate deliberately narrow. These are existing
# upstream tests using only the committed synthetic fixtures; payment and
# meeting-specific coverage remains disabled.
run_product_check "workflows/events/events.spec.js" "organizer can create and delete an event"
run_product_check "workflows/rsvp/rsvp.spec.js" "approved RSVP requests are claimed through checkout"
run_product_check "workflows/waitlist/waitlist.spec.js" "a waitlisted user is promoted when the attendee leaves"
run_product_check "site/event/check-in.spec.js" "attendee can submit the public check-in form"

info "PASS: private synthetic Aachen product E2E completed for event creation, RSVP, waitlist, and check-in."

#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility entry point retained for the existing Aachen workflow. The
# previous cluster-local runner used a TCP proxy/service hop; the unchanged
# upstream suite has an explicit 5-second page.goto budget and the workflow logs
# proved that hop repeatedly exceeded it. Run the test-only Playwright sidecar
# next to the exact private server container instead, preserving upstream's
# 127.0.0.1:9000 contract without modifying OCG or tests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sidecar_script="$SCRIPT_DIR/private-product-e2e-sidecar-run.sh"
tmp_script="$(mktemp "$SCRIPT_DIR/.private-product-e2e-sidecar-run.XXXXXX")"
trap 'rm -f "$tmp_script"' EXIT INT TERM

cp "$sidecar_script" "$tmp_script"

# Two runs on the same exact control commit proved that the private runtime is
# healthy while waitlist teardown can still reload attendance state before its
# controls hydrate. Change only the temporary runner copy: allow each hydration
# attempt up to 30 seconds, perform at most one reload, and still fail closed if
# neither valid attendance control appears after the second bounded attempt.
[[ "$(grep -Fc 'for (let attempt = 0; attempt < 3; attempt += 1) {' "$tmp_script")" -eq 1 ]] || {
  echo 'Expected exactly one three-attempt attendance helper in sidecar runner.' >&2
  exit 1
}
[[ "$(grep -Fc 'timeout: 10_000' "$tmp_script")" -eq 2 ]] || {
  echo 'Expected exactly two 10-second attendance-control waits in sidecar runner.' >&2
  exit 1
}
[[ "$(grep -Fc 'if (attempt < 2) {' "$tmp_script")" -eq 1 ]] || {
  echo 'Expected exactly one two-reload attendance helper in sidecar runner.' >&2
  exit 1
}

sed -i \
  -e 's/for (let attempt = 0; attempt < 3; attempt += 1) {/for (let attempt = 0; attempt < 2; attempt += 1) {/' \
  -e 's/timeout: 10_000/timeout: 30_000/g' \
  -e 's/if (attempt < 2) {/if (attempt < 1) {/' \
  "$tmp_script"

[[ "$(grep -Fc 'for (let attempt = 0; attempt < 2; attempt += 1) {' "$tmp_script")" -eq 1 ]] || exit 1
[[ "$(grep -Fc 'timeout: 30_000' "$tmp_script")" -ge 2 ]] || exit 1
[[ "$(grep -Fc 'if (attempt < 1) {' "$tmp_script")" -eq 1 ]] || exit 1

bash "$tmp_script"

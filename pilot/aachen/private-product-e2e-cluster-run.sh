#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility entry point retained for the existing Aachen workflow. The
# previous cluster-local runner used a TCP proxy/service hop; the unchanged
# upstream suite has an explicit 5-second page.goto budget and the workflow logs
# proved that hop repeatedly exceeded it. Run the test-only Playwright sidecar
# next to the exact private server container instead, preserving upstream's
# 127.0.0.1:9000 contract without modifying OCG or tests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/private-product-e2e-sidecar-run.sh"

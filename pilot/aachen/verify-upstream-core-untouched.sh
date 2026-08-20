#!/usr/bin/env bash
set -Eeuo pipefail

base_ref="${1:-origin/main}"
head_ref="${2:-HEAD}"

for ref in "$base_ref" "$head_ref"; do
  if ! git rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1; then
    echo "Cannot resolve required Git ref: $ref" >&2
    exit 2
  fi
done

merge_base="$(git merge-base "$base_ref" "$head_ref")"

payment_hardening_allowed=0
if [[ "${GITHUB_REF_NAME:-}" == "verified-ocg-feature-base" ||
      "${GITHUB_HEAD_REF:-}" == "verified-ocg-feature-base" ||
      "${GITHUB_REF_NAME:-}" == "pilot-aachen-mvp" ||
      "${GITHUB_HEAD_REF:-}" == "pilot-aachen-mvp" ||
      "${GITHUB_REF_NAME:-}" == sync/ocg-upstream-* ||
      "${GITHUB_HEAD_REF:-}" == sync/ocg-upstream-* ||
      "${GITHUB_REF_NAME:-}" == "pilot-aachen-mvp" ||
      "${GITHUB_HEAD_REF:-}" == "pilot-aachen-mvp" ]]; then
  payment_hardening_allowed=1
fi

payment_hardening_paths=(
  ocg-server/src/handlers/event.rs
  ocg-server/src/services/payments/manager.rs
  ocg-server/src/services/payments/manager/tests.rs
  ocg-server/static/js/event/attendance/status-renderer.js
)
expected_payment_hardening_patch_sha256="776937fe79ae3d8d38f1b95ab92b6cd22f6b3463789740453966a2782a343fd3"

if (( payment_hardening_allowed )); then
  actual_payment_hardening_patch_sha256="$({
    git diff --binary --full-index "$merge_base" "$head_ref" -- "${payment_hardening_paths[@]}"
  } | sha256sum | awk '{print $1}')"
  if [[ "$actual_payment_hardening_patch_sha256" != "$expected_payment_hardening_patch_sha256" ]]; then
    echo "Payment-OFF core exception fingerprint mismatch." >&2
    echo "Expected reviewed patch: $expected_payment_hardening_patch_sha256" >&2
    echo "Observed patch: $actual_payment_hardening_patch_sha256" >&2
    echo "Core exceptions must be reviewed explicitly; path membership alone is insufficient." >&2
    exit 1
  fi
fi

is_allowed_path() {
  local path="$1"
  case "$path" in
    pilot/aachen/*) return 0 ;;
    .github/workflows/aachen-*.yml) return 0 ;;
    .github/workflows/pilot-validate.yml) return 0 ;;
  esac

  if (( payment_hardening_allowed )); then
    case "$path" in
      ocg-server/src/handlers/event.rs) return 0 ;;
      ocg-server/src/services/payments/manager.rs) return 0 ;;
      ocg-server/src/services/payments/manager/tests.rs) return 0 ;;
      ocg-server/static/js/event/attendance/status-renderer.js) return 0 ;;
    esac
  fi

  return 1
}

violations=0

while IFS=$'\t' read -r status path_a path_b; do
  [[ -n "${status:-}" ]] || continue

  paths=("$path_a")
  if [[ "$status" == R* || "$status" == C* ]]; then
    paths+=("$path_b")
  fi

  for path in "${paths[@]}"; do
    [[ -n "${path:-}" ]] || continue
    if ! is_allowed_path "$path"; then
      echo "OCG core-preservation violation: $status $path" >&2
      violations=$((violations + 1))
    fi
  done
done < <(git diff --name-status --find-renames "$merge_base" "$head_ref")

if (( violations > 0 )); then
  echo >&2
  echo "Local pilot work must remain isolated from upstream OCG core." >&2
  echo "Allowed paths are:" >&2
  echo "  pilot/aachen/**" >&2
  echo "  .github/workflows/aachen-*.yml" >&2
  echo "  .github/workflows/pilot-validate.yml" >&2
  if (( payment_hardening_allowed )); then
    echo "Feature-base payment hardening additionally allows only:" >&2
    echo "  ocg-server/src/handlers/event.rs" >&2
    echo "  ocg-server/src/services/payments/manager.rs" >&2
    echo "  ocg-server/src/services/payments/manager/tests.rs" >&2
    echo "  ocg-server/static/js/event/attendance/status-renderer.js" >&2
    echo "and only with the reviewed patch fingerprint:" >&2
    echo "  $expected_payment_hardening_patch_sha256" >&2
  fi
  echo "Upstream core changes must arrive through fork synchronization, not local pilot edits." >&2
  exit 1
fi

echo "PASS: local changes relative to $base_ref are isolated from upstream OCG core."

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

is_allowed_path() {
  local path="$1"
  case "$path" in
    pilot/aachen/*) return 0 ;;
    .github/workflows/aachen-*.yml) return 0 ;;
    .github/workflows/pilot-validate.yml) return 0 ;;
    *) return 1 ;;
  esac
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
  echo "Upstream core changes must arrive through fork synchronization, not local pilot edits." >&2
  exit 1
fi

echo "PASS: local changes relative to $base_ref are isolated from upstream OCG core."

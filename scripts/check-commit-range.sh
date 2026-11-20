#!/usr/bin/env bash
# Apply scripts/check-commit-message.sh to every subject in a revision range.
# CI sets EVENT_NAME. A local call can pass the two endpoints instead:
#   scripts/check-commit-range.sh <base> <head>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-commit-message.sh"

if [[ $# -eq 2 ]]; then
  base="$1"
  head="$2"
elif [[ "${EVENT_NAME:-}" == "pull_request" ]]; then
  base="${BASE_SHA:?pull request base sha required}"
  head="${HEAD_SHA:?pull request head sha required}"
else
  before="${PUSH_BEFORE:-}"
  head="${PUSH_AFTER:-HEAD}"
  if [[ -z "$before" || "$before" =~ ^0+$ ]]; then
    base="origin/${DEFAULT_BRANCH:-main}"
  else
    base="$before"
  fi
fi

subjects="$(git -C "$ROOT" log --format=%s "${base}..${head}")"

failed=0
if [[ -n "$subjects" ]]; then
  while IFS= read -r subject || [[ -n "$subject" ]]; do
    [[ -z "$subject" ]] && continue
    if ! "$CHECK" -m "$subject"; then
      failed=1
    fi
  done <<<"$subjects"
fi

exit "$failed"

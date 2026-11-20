#!/usr/bin/env bash
# Apply scripts/check-commit-message.sh to every subject in a revision range.
# CI sets EVENT_NAME. A local call can pass the two endpoints instead:
#   scripts/check-commit-range.sh <base> <head>
#
# PUSH_BEFORE is the tip before a push. Checkout's full-history refspec
# fetches current refs only, so after a rebase and force-push that SHA is
# not in the clone, and a later fetch of the default branch does not ask
# for it either. git log then fails before any subject is checked.
#
# Policy for that previous tip:
#   1. Use it when this checkout already has the commit.
#   2. Otherwise fetch that SHA from origin and use it if the object arrives.
#   3. If origin will not serve it, fall back to origin/$DEFAULT_BRANCH,
#      the same base as a newly created branch. Subjects on the new tip
#      that are not on the default branch are still checked. The old tip's
#      exclusive commits are not, because the remote no longer has them.
#      A force-push of the default branch itself then has an empty range:
#      the fetched default branch is already the new tip.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-commit-message.sh"

is_commit() {
  git -C "$ROOT" rev-parse --verify --quiet --end-of-options "${1}^{commit}" >/dev/null
}

if [[ $# -eq 2 ]]; then
  base="$1"
  head="$2"
elif [[ "${EVENT_NAME:-}" == "pull_request" ]]; then
  base="${BASE_SHA:?pull request base sha required}"
  head="${HEAD_SHA:?pull request head sha required}"
else
  before="${PUSH_BEFORE:-}"
  head="${PUSH_AFTER:-HEAD}"
  fallback="origin/${DEFAULT_BRANCH:-main}"
  if [[ -z "$before" || "$before" =~ ^0+$ ]]; then
    base="$fallback"
  elif [[ ! "$before" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "PUSH_BEFORE is not a commit SHA. Checking ${fallback}..${head}." >&2
    base="$fallback"
  elif is_commit "$before"; then
    base="$before"
  else
    echo "Previous tip ${before} is not in this checkout; fetching it from origin." >&2
    # Prompt-less: a missing credential must fail the fetch, not hang CI.
    if ! GIT_TERMINAL_PROMPT=0 git -C "$ROOT" fetch --no-tags origin "$before"; then
      echo "Could not fetch previous tip ${before}." >&2
    fi
    if is_commit "$before"; then
      base="$before"
    else
      echo "Previous tip ${before} is unavailable. Checking ${fallback}..${head}." >&2
      base="$fallback"
    fi
  fi
fi

if ! is_commit "$base"; then
  echo "Commit range base is not in this checkout: ${base}" >&2
  exit 1
fi
if ! is_commit "$head"; then
  echo "Commit range head is not in this checkout: ${head}" >&2
  exit 1
fi

# SHA<TAB>subject for every commit. A subject-only list loses a trailing
# empty subject inside $(...), and a blank line was skipped, so
# `git commit --allow-empty-message` never reached the checker.
records="$(git -C "$ROOT" log --format='%H%x09%s' "${base}..${head}")"

failed=0
if [[ -n "$records" ]]; then
  while IFS= read -r record || [[ -n "$record" ]]; do
    [[ -z "$record" ]] && continue
    sha="${record%%$'\t'*}"
    subject="${record#*$'\t'}"
    if ! "$CHECK" -m "$subject"; then
      echo "Commit ${sha}" >&2
      failed=1
    fi
  done <<<"$records"
fi

exit "$failed"

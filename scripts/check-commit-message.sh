#!/usr/bin/env bash
# Reject a commit subject that is not Conventional Commits.
#   type: subject
#   type(scope): subject
# Scope is optional. Types: feat, fix, docs, style, refactor, test, chore, ci
#
#   scripts/check-commit-message.sh -m "feat: add button"
#   scripts/check-commit-message.sh -m "feat(client): add button"
#   scripts/check-commit-message.sh path/to/COMMIT_EDITMSG
set -euo pipefail

pattern='^(feat|fix|docs|style|refactor|test|chore|ci)(\([^[:space:])]+\))?: [^[:space:]].*$'

usage() {
  echo "Usage: check-commit-message.sh -m <subject> | check-commit-message.sh <message-file>" >&2
  exit 2
}

# First non-empty, non-comment line. Git may leave a template of # lines
# in the message file when cleanup has not run yet.
extract_subject() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi
    printf '%s\n' "$line"
    return 0
  done
  return 1
}

reject() {
  local subject="$1"
  echo "Not a conventional commit subject: ${subject}" >&2
  echo "Expected type: subject or type(scope): subject" >&2
  echo "Types: feat, fix, docs, style, refactor, test, chore, ci" >&2
  exit 1
}

if [[ $# -eq 2 && "$1" == "-m" ]]; then
  text="$2"
elif [[ $# -eq 1 && "$1" != "-m" ]]; then
  if [[ ! -f "$1" ]]; then
    echo "Commit message file not found: $1" >&2
    exit 1
  fi
  text="$(cat "$1")"
else
  usage
fi

if ! subject="$(extract_subject <<<"$text")"; then
  reject "(empty)"
fi

shopt -u nocasematch
if [[ ! "$subject" =~ $pattern ]]; then
  reject "$subject"
fi

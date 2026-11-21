#!/usr/bin/env bash
# Point this clone at the hook scripts committed in .githooks/.
# Does not need Node, Flutter, or Cargo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
git -C "$ROOT" config core.hooksPath .githooks
echo "Hooks installed. This clone will use .githooks/."
echo "A later git commit is refused only when the branch is main or master."
echo "Any branch: the subject must match type: subject or type(scope): subject."

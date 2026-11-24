#!/usr/bin/env bash
# Format, lint, and test. A laptop and CI run this script.
# Commit subjects stay in scripts/check-commit-message.sh.
# This script does not parse commit messages.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The only ed25519 string the repo is allowed to track. Tests use it as a
# placeholder. Any other ed25519 token of 32 or more base58 characters fails,
# including one that starts with this placeholder.
FIXTURE='ed25519:11111111111111111111111111111111'

reject_secrets() {
  local path base
  # .Env and Credentials.json are the same files on a case-sensitive checkout.
  shopt -s nocasematch
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    base="${path##*/}"
    case "$base" in
      .env.example) ;;
      .env | .env.* | .dev.vars | credentials.json | dart_defines.json)
        echo "Tracked secret file: $path" >&2
        exit 1
        ;;
    esac
    case "$path" in
      neardev/* | */neardev/* | .near-credentials/* | */.near-credentials/*)
        echo "Tracked secret file: $path" >&2
        exit 1
        ;;
    esac
  done < <(git -C "$ROOT" ls-files)
  shopt -u nocasematch

  local hits status line tokens token bad
  # Exit 1 means no match. Any other non-zero status is a real git failure.
  set +e
  hits="$(git -C "$ROOT" grep -I -n -E \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    -e 'ed25519:[1-9A-HJ-NP-Za-km-z]{32,}' \
    -- .)"
  status=$?
  set -e
  if [[ "$status" -eq 1 ]]; then
    return 0
  fi
  if [[ "$status" -ne 0 ]]; then
    echo "git grep failed while scanning for private keys" >&2
    exit 1
  fi
  if [[ -z "$hits" ]]; then
    return 0
  fi

  bad=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *'-----BEGIN '*'PRIVATE KEY-----'* ]]; then
      bad="${bad}${line}"$'\n'
      continue
    fi
    # Match the whole token. Stripping the fixture as a prefix would hide a
    # longer key that begins with it.
    tokens="$(printf '%s\n' "$line" | grep -oE 'ed25519:[1-9A-HJ-NP-Za-km-z]{32,}' || true)"
    while IFS= read -r token; do
      [[ -z "$token" ]] && continue
      if [[ "$token" != "$FIXTURE" ]]; then
        bad="${bad}${line}"$'\n'
        break
      fi
    done <<< "$tokens"
  done <<< "$hits"
  if [[ -n "$bad" ]]; then
    echo "Private key material is tracked:" >&2
    printf '%s' "$bad" >&2
    exit 1
  fi
}

require_toolchain_files() {
  local channel action
  channel="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$ROOT/contracts/rust-toolchain.toml")"
  action="$(sed -n 's/^[[:space:]]*uses: dtolnay\/rust-toolchain@\([^[:space:]]*\).*/\1/p' "$ROOT/.github/workflows/check.yml")"
  if [[ -z "$channel" || -z "$action" || "$action" != "$channel" ]]; then
    echo "check.yml installs Rust ${action:-missing}; contracts/rust-toolchain.toml says ${channel:-missing}" >&2
    exit 1
  fi
}

require_pinned_rustc() {
  local expected actual
  expected="$(sed -n 's/^channel = "\(.*\)"/\1/p' "$ROOT/contracts/rust-toolchain.toml")"
  actual="$(rustc --version | awk '{print $2}')"
  if [[ -z "$expected" || "$actual" != "$expected" ]]; then
    echo "rustc ${actual:-unknown} does not match contracts/rust-toolchain.toml (${expected:-missing})" >&2
    exit 1
  fi
}

require_pinned_flutter() {
  local expected actual
  expected="$(sed -n 's/^[[:space:]]*flutter-version:[[:space:]]*"\(.*\)".*/\1/p' "$ROOT/.github/workflows/check.yml")"
  actual="$(flutter --version | awk 'NR==1 { print $2 }')"
  if [[ -z "$expected" || "$actual" != "$expected" ]]; then
    echo "Flutter ${actual:-unknown} does not match .github/workflows/check.yml (${expected:-missing})" >&2
    exit 1
  fi
}

reject_secrets
require_toolchain_files

cd "$ROOT/contracts"
require_pinned_rustc
# --locked refuses a Cargo.lock that does not match the manifests.
cargo --locked fmt --check
# A host `cargo clippy` with no target selection does not enable
# dev-dependencies, and near-sdk 5.30.0 then rejects the build.
# `--all-targets` enables them, so the host library and its tests are linted.
# Do not pass `--cfg clippy` in RUSTFLAGS: aws-lc-sys turns that into a
# nightly feature and the build fails on stable.
# The wasm target is a separate build. It is the one that deploys, and it
# does not use the unit-testing dev-dependency.
cargo --locked clippy --target wasm32-unknown-unknown --workspace
cargo --locked clippy --all-targets --workspace
cargo --locked test --workspace

cd "$ROOT/client"
require_pinned_flutter
# --output=none checks without rewriting the tree. --set-exit-if-changed
# alone formats files and then exits 1, so a local run would dirty the client.
dart format --output=none --set-exit-if-changed .
# Fail when pubspec.lock does not match pubspec.yaml, instead of rewriting it.
flutter pub get --enforce-lockfile
flutter analyze
flutter test

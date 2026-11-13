#!/usr/bin/env bash
# Alice on the iOS simulator, Bob on the Android emulator.
# Keys are loaded at runtime from the local mailbox (/dev/cred), not the CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTRACT="${MATCH_CONTRACT:-play.engkwentro.testnet}"
RPC="${NEAR_RPC:-https://rpc.testnet.near.org}"
IOS_ID="${IOS_DEVICE_ID:-8CEA1C19-485E-4719-B3FE-B8DEB2433549}"
AND_ID="$(flutter devices 2>/dev/null | awk -F'•' '/android/{gsub(/ /,"",$2); print $2; exit}')"

# Optional REOWN_PROJECT_ID from repo .env (Flutter still needs --dart-define).
if [[ -z "${REOWN_PROJECT_ID:-}" && -f "$ROOT/.env" ]]; then
  REOWN_PROJECT_ID="$(
    grep -E '^REOWN_PROJECT_ID=' "$ROOT/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"
  )"
  export REOWN_PROJECT_ID
fi

DEFINES=(
  "--dart-define=MATCH_CONTRACT=$CONTRACT"
  "--dart-define=NEAR_RPC=$RPC"
)
if [[ -f "$ROOT/client/dart_defines.json" ]]; then
  DEFINES+=("--dart-define-from-file=$ROOT/client/dart_defines.json")
elif [[ -n "${REOWN_PROJECT_ID:-}" ]]; then
  DEFINES+=("--dart-define=REOWN_PROJECT_ID=$REOWN_PROJECT_ID")
fi

cd "$ROOT/client"
echo "iOS Alice → $IOS_ID"
echo "Android Bob → ${AND_ID:-not ready}"
if [[ -f dart_defines.json ]] || [[ -n "${REOWN_PROJECT_ID:-}" ]]; then
  echo "WalletConnect: REOWN_PROJECT_ID is set"
else
  echo "WalletConnect: no REOWN_PROJECT_ID (Create play account still works)"
fi

flutter run -d "$IOS_ID" \
  --dart-define=PLAYER_ROLE=A \
  --dart-define=MAILBOX_URL=http://127.0.0.1:8787 \
  "${DEFINES[@]}" &

if [ -n "${AND_ID:-}" ]; then
  flutter run -d "$AND_ID" \
    --dart-define=PLAYER_ROLE=B \
    --dart-define=MAILBOX_URL=http://10.0.2.2:8787 \
    "${DEFINES[@]}" &
fi

wait

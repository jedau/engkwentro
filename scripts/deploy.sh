#!/usr/bin/env bash
# Deploy the three v0.1.0 contracts. Requires funded testnet accounts.
#
# Match account: by default redeploy **without** init so live match state
# and Borsh layout stay intact. Pass INIT_MATCH=1 for a brand-new account.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATCH="${MATCH_ACCOUNT:-play.engkwentro.testnet}"
REGISTRY="${REGISTRY_ACCOUNT:-engkwentro-registry.testnet}"
VAULT="${VAULT_ACCOUNT:-engkwentro-vault.testnet}"
OWNER="${VAULT_OWNER:-engkwentro.testnet}"

cd "$ROOT/contracts/engkwentro"
if [[ "${INIT_MATCH:-0}" == "1" ]]; then
  cargo near deploy build-non-reproducible-wasm "$MATCH" \
    with-init-call init json-args '{}' \
    prepaid-gas '100.0 Tgas' attached-deposit '0 NEAR' \
    network-config testnet sign-with-keychain send
else
  cargo near deploy build-non-reproducible-wasm "$MATCH" \
    without-init-call \
    network-config testnet sign-with-keychain send
fi

cd "$ROOT/contracts/engkwentro-registry"
cargo near deploy build-non-reproducible-wasm "$REGISTRY" \
  with-init-call init json-args "{\"match_contract\":\"$MATCH\"}" \
  prepaid-gas '100.0 Tgas' attached-deposit '0 NEAR' \
  network-config testnet sign-with-keychain send

cd "$ROOT/contracts/engkwentro-vault"
cargo near deploy build-non-reproducible-wasm "$VAULT" \
  with-init-call init json-args "{\"owner\":\"$OWNER\"}" \
  prepaid-gas '100.0 Tgas' attached-deposit '0 NEAR' \
  network-config testnet sign-with-keychain send

echo "deployed $MATCH $REGISTRY $VAULT"

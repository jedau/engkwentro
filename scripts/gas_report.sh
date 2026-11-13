#!/usr/bin/env bash
# Local gas from the match crate unit tests. Testnet numbers replace these
# after scripts/deploy.sh when the accounts exist.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/contracts"
cargo test --workspace -- --nocapture 2>&1 | tee /tmp/engkwentro-gas.txt
echo
echo "gas kind= lines (TGas from env::used_gas in the simulator):"
grep -E "gas kind=" /tmp/engkwentro-gas.txt || true
echo "Write measured testnet rows into docs/GAS_BASELINE.md after deploy."

# ECONOMICS

**v0.1.0 — what ships.** Players pay their own testnet gas. Measured
numbers are in [`GAS_BASELINE.md`](GAS_BASELINE.md). Pricing knobs below
are for projecting mainnet stickers only.

## Measured (testnet, `play.engkwentro.testnet`)

| Action | TGas | NEAR burnt | USD at $3/NEAR |
|---|---:|---:|---:|
| Quiet `apply_moves` | 2.52 | 0.000230 | ~$0.00069 |
| `resolve_challenge` | 2.50 | 0.000228 | ~$0.00068 |
| `commit_setup` | 2.86–2.92 | 0.000264–0.000270 | ~$0.00080 |

A short fighting match (≈14 moves, 1 fight, setup) floors around
**0.005 NEAR** (~$0.015 at $3). Change `NEAR_PRICE_USD` in `.env.example`
for stickers; do not invent new TGas.

## Why cost looks like this

Every move is a transaction. Repetition, immobilisation, and breakthrough
need per-move state ([`FINDINGS.md`](FINDINGS.md) F1). Batch size one is
the live path (`apply_moves` with a single move + optional `think_ns`).

## Stakes (optional)

Match stake is peer-to-peer and opt-in. The Create dialog takes a **NEAR
amount** (default `0` = no wager). Creator attaches that deposit on
`create_match`; joiner attaches the same on `accept_match` /
`accept_match_by_key`. Winner takes the pot minus a 1.5% rake via
`claim_payout` after settle. Free matches still work; players only pay gas.

## Vault / Pro (compiled, not required for the demo)

The vault crate models a **250 NEAR** Pro lock, 7-day unstake, and a
`min(50, staked * 15 / 250)` daily cap. It is **not** deployed on the
play account. Yield projections use `STAKING_APY` (default 5%). See
[`ROADMAP.md`](ROADMAP.md) for when this might ship.

## Not in v0.1.0

A subsidised free tier (meta-transactions / third-party submitter), ad
credits, and multi-move batching are **out of scope** for this cut. The
open-track story is the hidden-information pattern and measured gas, not
a live subsidy pool.

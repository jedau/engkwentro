# GAS_BASELINE — v0.1.0

Two columns. **Simulator** is `env::used_gas` inside the NEAR unit-test
VM (`used_gas / 1e12` logs `0` because each call is under 1 TGas).
**Testnet** is `tokens_burnt` on `play.engkwentro.testnet` (FastNEAR
archival), gas price `100000000` yocto/gas, 2026-11-01.

USD column uses the **$3 / NEAR** knob in `docs/ECONOMICS.md`.

| Action | Simulator TGas | Testnet TGas | Testnet NEAR | Notes |
|---|---:|---:|---:|---|
| `commit_setup` | < 1 | 2.86–2.92 | 0.000264–0.000270 | 21 × 32-byte commitments |
| `confirm_roster` (first) | < 1 | 2.57 | 0.000234 | fills occupancy; reuses `first` from accept |
| `confirm_roster` (second) | < 1 | 1.91 | 0.000169 | no-op after `Committed` |
| `apply_moves` (quiet) | < 1 | **2.52** | **0.000230** | match 6, Alice `F4QCNoc…`, Bob first step |
| `resolve_challenge` | — | **2.50** | **0.000228** | match 6 Alice `8KQ5xW…`, `AttackerWins` + flag |
| `create_match` / `accept_match` | < 1 | ~2.5 | ~0.00024 | estimated at apply rate |
| `resign` | < 1 | — | — | hit in scripted match 2, not re-measured |
| `submit_setup` / `settle` / `claim_payout` | < 1 | — | — | match 2 only; match 6 still `AwaitingFlip` |
| `vault.stake` | — | — | — | not on the free-play path |
| `registry.apply_result` | — | — | — | not deployed to this play account |

Quiet move and fight **report** cost the same order of magnitude. The
fight is expensive in *time* (OT + two reports + 1 s poll), not in NEAR.

Lifetime on the two funded accounts (from 3.000 NEAR each, all match
ids 1–6): Alice **0.009260**, Bob **0.008244**, together **0.01750 NEAR**
(~$0.053). About **0.00023 NEAR/tx**.

Match 6 reconstructed floor (14 moves, 1 fight, setup): **~0.0051 NEAR**.
Four fights would be ~0.0065. Flip is not in that bill.

Run:

```bash
scripts/gas_report.sh
```

The match crate still logs `gas kind=... tgas=...` (integer TGas, so
`0` on testnet too). Prefer `tokens_burnt` on the receipt.

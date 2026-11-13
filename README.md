# Engkwentro

**Tracks:** `games`, `open`  
**Version:** 0.1.0  
**Deadline:** NEAR Hackathon, 2026-11-14T23:59:00Z  
**Chain:** NEAR **testnet** — `play.engkwentro.testnet`  
**Landing:** [jedau.github.io/engkwentro](https://jedau.github.io/engkwentro/) ([`docs/index.html`](docs/index.html))

A hidden-information board game (Game of the Generals) where fog of war
survives a transparent ledger. The game is the demo. The transferable
artifact is the pattern in [`docs/FINDINGS.md`](docs/FINDINGS.md).

Weight for judges: **`open` first** (architecture, measured gas, published
dead ends), **`games` second** (two-device match on testnet).

## Getting Started

Install, accounts, and two-phone run: **[`docs/SETUP.md`](docs/SETUP.md)**.

```bash
# Tests (offline)
cd contracts && cargo test -p engkwentro    # 40 passed
cd client && flutter test                   # 59 passed

# Play on testnet (two devices)
node scripts/mailbox_local.mjs              # terminal 1
scripts/run_two_phones.sh                   # or two flutter run sessions
```

Connect Wallet → Create play account or Demo Alice/Bob → Create / Join.  
Optional WalletConnect: copy `client/dart_defines.json.example` → set
`REOWN_PROJECT_ID` → `--dart-define-from-file=dart_defines.json`.

## The problem

A public chain shows every byte it stores. Game of the Generals needs 21
face-down ranks per side. If the contract holds ranks, spectators read
them. If it holds only a Merkle root, it cannot check composition
([`docs/FINDINGS.md`](docs/FINDINGS.md) F2). If it decrypts mid-game, the
decrypt key is a platform secret.

## How NEAR fits

NEAR gas is cheap enough that **every move is a transaction** (F1:
off-chain moves cannot detect repetition, immobilisation, or
breakthrough). Measured on testnet:

| Action | TGas | NEAR burnt |
|---|---:|---:|
| Quiet `apply_moves` | 2.52 | **0.000230** |
| `resolve_challenge` | 2.50 | **0.000228** |
| `commit_setup` | 2.86–2.92 | 0.000264–0.000270 |

USD uses the **$3 / NEAR** and **5% APY** knobs in
[`docs/ECONOMICS.md`](docs/ECONOMICS.md). Change those two numbers; do not
change the TGas column (`docs/GAS_BASELINE.md`).

**Option 2** (no platform decrypt key, no Merkle):

1. Each piece is `sha256(rank || salt)` (32 bytes) on a square.
2. A fight is 1-of-15 OT off-chain. Both players report the same
   `Exchange`. The contract never sees ranks mid-game.
3. After `Ended`, each side `submit_setup`. The contract checks hashes,
   `COMPOSITION`, and the fight log. `settle` is permissionless.

The match contract makes **zero outbound calls**. First mover is a
SHA-256 bit at accept (not “creator always moves first”).

Players **sign and submit** their own transactions.

Known hole: a hostile client can feed OT a fake rank (Alice’s Five-star,
F9). The flip slashes later. Delayed audit, not live-trustless.

## Hackathon build window

Built for the NEAR Hackathon ending **2026-11-14**. Work in this tree is
the submission. Disclose any baseline from before 2026-10-19 in the
application if applicable.

## Technical architecture

Three contracts. Only the match crate is live on testnet.

| Contract | Job | Outbound | Deployed |
|---|---|---|---|
| match | setup, play, OT reports, flip, join keys | none | `play.engkwentro.testnet` |
| registry | integer Elo (`RULES.md` §11) | view match | no |
| vault | 250 NEAR Pro lock, 7-day unstake | none | no |

State is one `LookupMap<MatchId, Match>`, not a contract per match.
Join keys use standalone maps so upgrading does not break live Borsh
layout (redeploy **without** `init`).

The Flutter client uses a single `MatchDriver` writer, one `get_sync`
row per refresh, and think-time charging (`think_ns`, 5 s network cap).
Details: [`docs/CLOCKS.md`](docs/CLOCKS.md).

**Contributions** (see [`docs/FINDINGS.md`](docs/FINDINGS.md)):

1. Cheap non-ZK hidden state for a static hidden-information game.
2. Retroactive input audit: OT can lie; the flip replays the fight log.
3. Arbiter as a shared pure function (`arbiter.rs` `MATRIX` →
   `client/lib/arbiter.g.dart`). Do not regenerate the matrix.
4. Operator-death survivability: permissionless `settle` / timeout; no
   platform decrypt key.
5. Negative findings F1–F9, including why Merkle composition fails.

## Cost (measured, then priced)

| Action | Testnet TGas | Testnet NEAR | USD at $3/NEAR |
|---|---:|---:|---:|
| `apply_moves` (quiet) | 2.52 | 0.000230 | $0.00069 |
| `resolve_challenge` | 2.50 | 0.000228 | $0.00068 |
| `commit_setup` | 2.86–2.92 | 0.000264–0.000270 | ~$0.00080 |

Match 6 floor (14 moves, 1 fight, setup): **~0.0051 NEAR** (~$0.015 at
$3). A subsidised free tier remains an open product question (F4), not
what this cut demos.

## Limitations

Testnet, unaudited. Live path is player-signed, player-submitted. Alice’s
Five-star is delayed audit. Salts are in-memory until flip — do not kill
the app mid-match. Home-row Flag breakthrough is silent in the UI; the
board shows the piece, and the win is declared when the reply does not
challenge that square ([`docs/RULES.md`](docs/RULES.md) §7.2).

## Submission

POST `https://nearhackathon.com/api/applications` (JSON, ≤12000 bytes).
Fields only: `requestId`, `projectName`, `leadName`, `email`, `size`,
`tracks`, `nearAddress`, `projectUrl`, `demoUrl`, `idea`, `consent`.
Do **not** send `website`. `nearAddress` must be **mainnet**, lowercase.
`tracks`: include `games` and `open`. Repo public + demo online **before**
submit — cannot edit after. Rules: [HACKATHON.md](https://nearhackathon.com/HACKATHON.md).

## Docs

| | |
|---|---|
| [`docs/SETUP.md`](docs/SETUP.md) | Getting Started — toolchain, accounts, two-phone |
| [`docs/FINDINGS.md`](docs/FINDINGS.md) | Dead ends — read this |
| [`docs/RULES.md`](docs/RULES.md) | Canonical game spec |
| [`docs/CLOCKS.md`](docs/CLOCKS.md) | Turn / clock / overlay authority |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Split, state machine |
| [`docs/CLIENT.md`](docs/CLIENT.md) | Flutter, OT, auth |
| [`docs/TRUST.md`](docs/TRUST.md) | What is trustless |
| [`docs/ALTERNATIVES.md`](docs/ALTERNATIVES.md) | Worker vs 2PC vs ZK |
| [`docs/GAS_BASELINE.md`](docs/GAS_BASELINE.md) | Simulator + testnet |
| [`docs/ECONOMICS.md`](docs/ECONOMICS.md) | Measured gas + vault notes |
| [`CHANGELOG.md`](CHANGELOG.md) | v0.1.0 |

Game of the Generals invented by Sofronio H. Pasola Jr., 1970. Rules are
not copyrightable. MIT.

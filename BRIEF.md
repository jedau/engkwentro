# BRIEF.md — Engkwentro on NEAR

**Product version: 0.1.0** (initial implementation). See `CHANGELOG.md`.

> **Status 2026-11-13.** Live path: player signs **and submits** (predecessor).
> Connect Wallet: in-app create play account + logo-first wallets
> (WalletConnect first). MyNearWallet is retired. Piece SVGs are wired
> via `PieceArt`. §7 build calendar is historical.

Read this fully before writing code. Do not relitigate LOCKED items without a
concrete reason.

## 1. Mission

Build **Engkwentro** — a chess.com-inspired competitive platform for Game of the
Generals, the Filipino board game invented in 1970 by Sofronio H. Pasola Jr.
Verifiable, hidden-information, with a real player-owned economy.

Target: NEAR HACKATHON. Deadline 2026-11-14T23:59:00Z. Tracks: `games`, `open`.

Thesis, and the thing every design choice serves:
  A hidden-information board game cannot be run fairly on a transparent ledger
  without a design. We solve it with per-piece `sha256(rank || salt)`, a
  shared arbiter table, and 1-of-15 OT: players report `Exchange`, the
  contract never sees ranks mid-game. The worker decrypt path was dismissed
  2026-11-01 (`docs/ALTERNATIVES.md`).

**The game is a demonstration vehicle.** The transferable artifact is the pattern —
see `docs/FINDINGS.md`. Weight the README toward the architecture, not the
tokenomics: `open` judges the strong part, `games` judges the weak part. Submit to
both, emphasise the former.

## 2. LOCKED decisions

- Chain: NEAR. Single chain.
- Contract language: Rust (near-sdk). Dart is client-only.
- Client: Flutter/Dart.
- Live client is a signer **and submitter**: the player account is the
  predecessor.
- Login: Connect sheet with in-app **Create play account** (local
  Ed25519 + testnet faucet → secure storage), logo-first wallets with
  **WalletConnect first** (WebView SignClient; needs
  `REOWN_PROJECT_ID`), and `near_wallet_connect` deep links for wallets
  that return a function-call key. MyNearWallet is retired (31 Oct
  2026). Gameplay requires a local signing key — WC identity alone is
  not enough. On simulators use Demo Alice/Bob mailbox accounts.
- **Fixed contract set: match, registry, vault. Never a contract per match.**
  Only match is deployed for the demo.
- **Ranks are sealed per match, not Merkle-committed.** Each piece is
  `sha256(rank || salt)` (32 bytes). Fights use 1-of-15 OT off-chain; both
  players report the same `Exchange`. Composition is checked on the flip.
  First player is a SHA-256 bit at **`accept_match`** (reused at
  `confirm_roster`). No platform SK, no `crypto_box_seal`, no
  `merkle.rs`. (The worker-keypair bullet was superseded 2026-11-01;
  see `docs/ALTERNATIVES.md`.)
- NEP-297 events for match lifecycle. A compact `fight_log` is kept on
  the match for the flip audit (not a full move VOD).
- Timeout / settle enforcement is **permissionless** (any account; caller
  pays gas). No bounty payout in v0.1.0.
- **Vault stakes NEAR directly. No LST, no DEX, no harvest cron.** Yield is simulated
  from `STAKING_APY` on testnet and read from a real staking pool on mainnet.
- **Stakes are opt-in per match.** Unstaked matches still require the
  player to pay gas.
- **Escrow is decoupled from Elo and records.**
- **Ladder is the integer Elo in `docs/RULES.md` §11.** Start 1200, K=48, ADV=50,
  floor 25, forfeit and void 55. One signed transfer `t`. No floats.
- **The match contract makes zero outbound cross-contract calls.** Players
  submit inbound `resolve_challenge` / `confirm_arrival`. There is no
  `verify_setup` oracle.
- **Every move is on-chain.** Repetition, immobilisation, and breakthrough
  all require per-move state; moves cannot be off-chain. The live testnet
  path is **player-signed, player-submitted**.
- **The arbiter table is a pure function.** `fn resolve(attacker, defender) -> Exchange`.
  No storage, no `env`, no `self`. Shared by contract and client.

## 3. Non-negotiable constraints

- Local OT mailbox (`scripts/mailbox_local.mjs`). Timeouts and `settle`
  are permissionless on-chain (any account). If the mailbox dies, players
  OT on another channel; the report window still runs. There is no Arbiter
  worker and no platform decrypt key.
- Players pay testnet gas. Create-play-account stores keys in secure
  storage (no seed phrase UI).
- Testnet is the primary deployment. Mainnet only for the prize address and one real
  vault deposit/exit.
- Never commit secrets.
- **Ladder finality:** the client must not show rating deltas on `Ended`. Ratings
  resolve only when settlement closes. Show the board result immediately; show the
  ladder result as pending.
- Repo must be public by 2026-11-14T23:59:00Z.

## 4. Game rules

`docs/RULES.md` is canonical. Summary only:

Board 9 columns × 8 rows (player-facing columns 1–9, rows 1–8; contract `file`
0–8, `board_rank` 0–7). 21 pieces per side, ranks hidden. Higher rank wins,
equal ranks mutual kill, SPY beats every officer, PVT is the only SPY killer, any piece captures the
FLG. Win by capturing the FLG, by flag breakthrough, by resignation, or by
immobilising the opponent. Draws by agreement or threefold repetition.
`COMPOSITION` is checked on the flip, not at kickoff. After the board ends
the client flips both armies automatically.

The match creator sets a chess-style clock: both players get the same bank,
whole minutes from 1 to 15, for the whole game. No per-move reset. Clocks
pause while both players report a fight. After the board ends the client
flips both armies automatically.

Double settlement failure is a void: both players take the ladder penalty and any
stakes are retained.

**Officer ladder, high to low:** 5*G, 4*G, 3*G, 2*G, 1*G, COL, LTC, MAJ, CPT, 1LT,
2LT, SGT. Plus 2 SPY, 6 PVT, 1 FLG. The inline notes in `docs/RULES.md` §2 and §6
flag what training data gets wrong.

## 5. Architecture

- `match contract` — matches as sub-state, escrow, settlement. Applies
  `Exchange` when both players report the same value. No outbound calls.
- `registry contract` — ladder (compiled; not on the play account).
- `vault` — Pro lock model (compiled; not on the play account).

State machine: `Created → Committed → InProgress → (WaitingForArbiter |
Breakthrough)* → Ended { outcome }`, with `SettlementStatus` detached.
`WaitingForArbiter` = dual player reports, not an external worker.

Arbiter: `arbiter.rs` is a pure `MATRIX` table (also `client/lib/arbiter.g.dart`).
A fight is 1-of-15 OT off-chain; both players report `Exchange`. Home-row
Flag uses `confirm_arrival`. The flip audits the fight log.

Permissionless calls (any account, caller pays gas): `claim_timeout`,
`claim_resolution_timeout`, `settle`. No cranker service.

## 6. Economic model

**Players pay gas.** Stakes are optional per match.

Two layers (do not conflate):

1. **Match stake** — optional, peer-to-peer. Winner takes both, minus a
   1.5% rake when used.
2. **Account stake-for-Pro** — vault lock of 250 NEAR (crate exists; not
   on the play account). Cap `min(50, staked * 15 / 250)` / day. 7-day
   unstake. Yield projections use 5% APY. Details: `docs/ECONOMICS.md`.

**Cost basis.** Every move is on-chain. Testnet quiet `apply_moves` is
**0.000230 NEAR**. A short fighting match floors ~0.005 NEAR. BRIEF’s old
~$0.14/match figure was a conservative mainnet-style projection; use
`docs/GAS_BASELINE.md` for measured TGas.

Known gap (F4): a subsidised free tier is underwater without conversion or
batching. That product model is **not** what v0.1.0 demos.

## 7. Build plan

Historical day-by-day calendar from the hackathon start. The shipped
tree is the source of truth (`CHANGELOG.md`, `docs/`). Do not re-run the
calendar as if the contracts were empty.

## 8. Mandatory gas instrumentation from day one

Testnet NEAR is worthless but testnet gas metering is real. Log `gas_burnt` per
function, build a TGas table, convert to mainnet USD at a configurable price, publish
a projection. Instrument from the first function. This is the evidence for every
economic claim.

## 9. README requirements

Written for a machine reader. What it is, the problem, how NEAR fits. Reproduction as
"do X → see Y". No marketing. Name the track hints used. State plainly that contracts
run on testnet and the cost model derives from measured gas with price and APY
parameterised. Include the "Technical architecture & contributions" section and link
`docs/FINDINGS.md` — the trust proof is the audit, and the credibility is the
negative findings.

## 10. Submission mechanics

- POST https://nearhackathon.com/api/applications, JSON, max 12000 bytes
- Fields ONLY: requestId, projectName, leadName, email, size, tracks, nearAddress,
  projectUrl, demoUrl, idea, consent
- Do NOT send a `website` field — spam trap
- requestId: generate ONCE, reuse on retries
- **Cannot be edited. Repo public + demo posted BEFORE submitting. `size` is final.**
- 409 = name or email already used
- Accepted 2026-11-01 to 2026-11-14 only
- nearAddress must be MAINNET, lowercase, `^(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+$`
- size ∈ "1", "2 - 4", "4 - 6", "6 - 8", "8+"
- tracks ∈ defi, thesis, privacy, business, swarms, security, agents, realworld, games,
  nfts, memecoins, social, open
- idea: 20–2000 chars

## 11. Code conventions

- Rust: near-sdk, tests before deploying. Every function gets a gas log line.
- Client: Flutter signs **and** submits (JSON-RPC). Player = predecessor.
- Deploy scripts under `scripts/`. Testnet gets reset.
- Keep BRIEF.md / `CHANGELOG.md` updated as decisions change.

## 12. Pickup

Read `README.md`, `docs/RULES.md`, `docs/CLOCKS.md`, and `docs/FINDINGS.md`.
The shipped tree is the source of truth. Ask before contradicting a LOCKED
item.
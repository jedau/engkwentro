# Alternatives and dismissals

**v0.1.0.** Decision log for how Engkwentro hides ranks. Write future posts
from this file; do not relitigate a row that already has a “why not.”
If we reopen one, add a dated note here rather than arguing from memory.

Related: `FINDINGS.md` (negative results from building), `TRUST.md` (who
can do what), `RULES.md` §13 (the live procedure).

---

## What we are optimizing

A public chain cannot store ranks in the clear. Someone, or some protocol,
must produce an `Exchange` (`AttackerWins` / `DefenderWins` / `BothEliminated`)
without publishing those ranks. `arbiter.rs` is only the table. It does not
choose who is allowed to run it.

“Decentralized” here means: **no third party can see both armies or post an
`Exchange` the two players did not both produce.**

---

## Rejected — platform worker (hybrid)

**How it worked.** A worker generated an X25519 key per match. Players sealed
`rank || salt` with `crypto_box_seal` (81 bytes). The match contract stored
opaque boxes. The worker decrypted all 42 at kickoff (`COMPOSITION`), decrypted
two boxes on a fight, called `resolve`, posted `resolve_challenge`. Only the
worker account could speak for resolution. After `Ended`, openings were checked
against the same boxes.

**What was trusted.** The worker held every secret, could invent an
`Exchange`, and if it died the game paused until the same process restarted.
Settlement flip was an after-the-fact audit, not a live check.

**Honest name.** A serverless decrypt service, not a decentralized game.

**Why it was built.** Fastest path to hidden ranks on NEAR without ZK.
Kickoff 42-count is possible when one party can see every rank.

**Why it was dismissed (2026-11-01).** The decrypt key *is* the product’s
trusted party. Option 2 (per-piece hash + dual OT reports) replaced it.
See the live procedure in `RULES.md` §13.

---

## Dismissed earlier (still dismissed)

| Idea | Why it is out | Finding / date |
|---|---|---|
| Moves off-chain, challenges only on-chain | Repetition, immobilisation, breakthrough need every position | F1 |
| Merkle root over 21 leaves | A root does not constrain `COMPOSITION`. 3 Spies / 0 Sergeant is a valid tree | F2 |
| Mid-game player reveal | Withholder wedges the fight; awarding the revealer is a guess | F3 |
| Derive arbiter SK from player keys | Both players (and anyone who saw both pks) can open every box | 2026-11-01 |
| Client timestamp as first-player bit | Grindable; contract has no wall clock | 2026-11-01 |
| Float Elo / independent rounding | Wasm has no floats; two `round`s break zero-sum | F7 |
| `VOID_PENALTY < FORFEIT_PENALTY` | The first failure should grief the second | F8 |
| Per-match contract | Deploy cost and upgrades scale with concurrency | ARCHITECTURE |
| LST / DEX vault | Extra market, harvest, depeg; Pro is a lock, not a yield product | locked |
| Replay VOD in v0.1.0 | Persist 42 ranks after flip; later, not a protocol fork | 2026-11-01 |

Do not revive Merkle or mid-game reveal to “help” Option 2. They fail for
the same reasons as before.

---

## Four ways to remove the oracle (2026-11-01 discussion)

### Option 1 — ZK proof of a fight

Commit to ranks with a SNARK-friendly hash. On a challenge, verify a proof
that “these two commitments open to ranks whose `MATRIX` cell is this
`Exchange`.” No decrypt key.

**Kept as a destination, not a build.** Right end-state on a public chain.
Wrong cost: throw away `crypto_box_seal`, write circuits, run a prover
Flutter will not host. NEAR has no cheap pairing precompile we can lean on.
Months.

### Option 2 — Two-party computation (chosen)

Each player already knows their own 21 ranks. A fight is a 1-of-15 table
lookup: attacker’s row of `MATRIX`, defender’s column. 1-out-of-15 oblivious
transfer gives only `MATRIX[a][d]`. Neither rank is revealed. Both players
then **report the same `Exchange` on-chain**. The contract applies it only
when they agree. A mute party loses on a resolution timeout. A mismatched
pair of reports voids. After `Ended`, each side opens `sha256(rank || salt)`
on-chain; `COMPOSITION` and every recorded `Exchange` are checked.

**Hot-seat / one process** still calls `resolve` locally — that *is* 2PC
with yourself. Networked play uses OT; `scripts/mailbox_local.mjs` carries
ciphertext, never a secret.

**Why this one.** Stays on NEAR. Removes the platform decrypt key. Reuses
the flip, the bonds, and the table we already have. Smallest private
computation in the game (two values in `0..=14`).

**What it is not.** Live-trustless. See “Alice’s Five-star” below.

### Option 3 — Confidentiality chain

Secret / Sapphire / Aztec-class: hidden state is a validator feature.

**Dismissed for this project.** It leaves NEAR. Trust moves to that set
(often a TEE vendor). Not “trustless,” and not the hackathon track.

### Option 4 — Threshold decrypt (t-of-n workers)

Shamir the match secret across hosts.

**Dismissed as a decentralization path.** Easiest patch to the current
Worker. *t* colluders still see every rank and can still post a fake
`Exchange`. A sturdier operator, not a different protocol.

---

## Alice’s Five-star (the catch, answered)

**Claim that sounds right:** we snapshot the board at kickoff; the client
and the board should stop Alice feeding a Five-star into a fight when she
committed a Private.

**What the chain actually stores at kickoff.** Occupancy: *which* of
Alice’s 21 pieces sits on which square (`1..=21`). Not ranks. The
commitment `sha256(rank || salt)` is bound to that piece index, but it is
opaque until the flip.

**What the client enforces.** The honest client. `TRUST.md` already says
a hostile client can produce a legal-but-bad move. Alice’s modified app
puts `rank = FiveStar` into the OT while piece #7’s commitment is a
Private. Bob’s OT only yields `A` / `D` / `B`. He cannot see the lie.

**What the board enforces.** From-square, to-square, side to move, nonce,
clocks, repetition, immobilisation. It never sees a rank mid-game. That is
the fog.

**What catches her.** The flip. Piece #7 opens as Private. The recorded
`Exchange` is replayed as `resolve(Private, Bob’s opened rank)`. Mismatch
→ she forfeits, regardless of who “won” the board. Same delayed audit we
already had against a lying worker. The change: **only a player can lie,
and only about their own input.** Nobody holds both armies.

Kickoff `COMPOSITION` (42-count before move one) is gone with the worker.
A 21-Flag roster plays until the flip, then forfeits. That is the price of
not having a god-view at setup. Honest clients still only place a legal
set. On-chain composition at `submit_setup` is now a contract check, not a
worker boolean.

**Deferred 2026-11-01.** Accepted risk for this cut. Do not bind OT inputs
to commitments in v0.1.0 (that is Option 1 / a later iteration). Flip
slash stays. Do not “fix” it with mid-game reveal (F3) or by putting the
worker SK back. Reopen only with a dated note and a design that proves
the OT row matches `sha256(rank || salt)` without publishing the rank.

---

## Why Option 2 now, not “after the hackathon”

The earlier “after” was schedule risk, not protocol merit. Option 2 **does**
make the resolution protocol two-party: NEAR stores commitments, the public
board, both reports, openings, and slashes. That is the chain doing
settlement and dispute, which is what we are on NEAR for. There is no
privileged worker; the mailbox is a local script only.

The residual risk is time: OT between two devices, abort windows, and
replacing 81-byte boxes. Hot-seat can ship the same rules without a
network. On-chain two-party `report` is the part that must land in this
cut so we do not keep a privileged `arbiter_worker`.

---

## Conversion cost (worker → Option 2)

| Keep | Drop | Add |
|---|---|---|
| `arbiter.rs` / `MATRIX` | `crypto_box_seal`, per-match X25519 SK | `sha256(rank \|\| salt)` per piece (32 B) |
| On-chain moves, clocks, repetition | `init(arbiter_worker)` privilege | Dual `report` of `Exchange` / arrival |
| Flip window, forfeit, void, rake | Worker `verify_setup` boolean | On-chain opening + `COMPOSITION` |
| Player-submitted moves | Kickoff 42-count | 5-minute resolution timeout |
| | `create_match(..., arbiter_pk)` | 1-of-15 OT in clients (networked) |

**Gas.** Seals (81 B × 42) become hashes (32 B × 42). Cheaper storage.
One fight becomes two small reports instead of one worker tx. Same order
of magnitude.

**Security you lose.** Live god-view audit at kickoff. A cheater can play
a whole match on an illegal roster and only pay at the flip.

**Security you gain.** No platform SK. No single host that can read every
game. `verify_setup` is a function, not a person.

**What we are not doing in the same breath.** Vault/registry still are
not required for a free match. ZK binding of OT inputs to commitments is
Option 1 and stays later.

---

## Live procedure (Option 2)

1. `create_match(opponent, stake, ruleset, clock_minutes)` — no platform decrypt key.
2. `commit_setup` — 21 × `(file, board_rank, sha256(rank || salt))` on home
   squares. Ranks stay on the device.
3. First player: `sha256(random_seed || match_id || creator || opponent)`
   bit 0 at **`accept_match`**. Either player `confirm_roster` once both
   committed. Occupancy from positions. No 42-count.
4. `apply_moves` (exactly one move + optional `think_ns`). A challenge or
   home-row step enters `WaitingForArbiter` (dual-player report wait).
5. Both players run OT (or local `resolve` on one device), then
   `resolve_challenge` / `confirm_arrival`. Equal reports apply. Unequal
   reports void. Silence until `resolution_deadline` forfeits the mute side.
6. `submit_setup` opens 21 `(rank, file, board_rank, salt)`. The contract
   checks the hash, the home squares, and `COMPOSITION`. No worker.
7. `settle` / `claim_payout` unchanged; ladder `apply_result` when registry is live.

---

## Do not reopen without a dated note

- Alice’s Five-star live bind in v0.1.0 — deferred 2026-11-01; flip only.
- Merkle “just for commitments” — F2 still applies to composition.
- Put the SK back “for kickoff only” — that is the worker again.
- Mid-game reveal to settle a 2PC dispute — F3.
- One NEAR key with resolution privilege — a hotter key can fake fights if
  a privileged reporter is ever reintroduced.

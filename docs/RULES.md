# docs/RULES.md — Engkwentro game specification

**Applies to v0.1.0.** The match crate implements this surface, including
play and settlement.

Implementation spec for Game of the Generals, the Filipino board game invented in
1970 by Sofronio H. Pasola Jr. Shipped as **Engkwentro**. Rules are not copyrightable;
all art is ours.

**The Arbiter is a deterministic rules engine.** Not AI. It never guesses, and it
never needs a server.

## 1. Board

- 9 columns × 8 rows = 72 squares
- Rectangular, no terrain, no special squares
- **Player-facing coordinates:** columns 1–9 (vertical), rows 1–8 (horizontal).
  The client never shows a zero origin. `Rank` in this spec is a piece type
  (Spy, Private, Flag), never a board axis.
- **Contract / wire coordinates:** `file` 0–8, `board_rank` 0–7.
  `file = column - 1`, `board_rank = row - 1`. Those are the coordinates on
  each stored commitment and on the end-game `submit_setup`.
- Player A home area: rows 1–3 (`board_rank` 0–2). **A's home row is row 1.**
- Player B home area: rows 6–8 (`board_rank` 5–7). **B's home row is row 8.**

## 2. Pieces

21 pieces per side. Positions are PUBLIC; ranks are HIDDEN from the opponent.

| Rank | ID | Count | Notes |
|---|---|---|---|
| Spy | SPY | 2 | special, reusable |
| Five-star General | 5*G | 1 | highest officer |
| Four-star General | 4*G | 1 | |
| Three-star General | 3*G | 1 | |
| Two-star General | 2*G | 1 | |
| One-star General | 1*G | 1 | |
| Colonel | COL | 1 | |
| Lieutenant Colonel | LTC | 1 | |
| Major | MAJ | 1 | |
| Captain | CPT | 1 | |
| First Lieutenant | 1LT | 1 | |
| Second Lieutenant | 2LT | 1 | |
| Sergeant | SGT | 1 | lowest officer |
| Private | PVT | 6 | lowest rank |
| Flag | FLG | 1 | the objective |
| **Total** | | **21** | |

> **Counts your priors will get wrong.** Many online summaries list 1 SPY and 7 PVT.
> Both are wrong: it is **2 SPY and 6 PVT**. The total is 21 either way, which is
> exactly why the error survives transcription. A One-star General is also a distinct
> rank — some ladders omit it and jump from Two-star straight to Colonel.

```
5*G > 4*G > 3*G > 2*G > 1*G > COL > LTC > MAJ > CPT > 1LT > 2LT > SGT
```

SPY and FLG sit outside the ladder. See §6.

## 3. Setup

- Each side places all 21 pieces anywhere within their own three home rows (27
  squares, **6 left empty**)
- No predetermined layout, no positional constraints
- The legal roster is fixed (21 + 21 = 42). The honest client only places those
  pieces. Ranks stay hidden from the opponent until the match ends.
- Each piece is packed as `rank_id` (the `Rank` discriminant, 0–14) plus 32
  bytes of salt, then hashed with SHA-256. The contract stores the 32-byte
  digest on the square. See §13.
- **Kickoff does not open the hashes.** `COMPOSITION` is checked on the flip.
  A liar can start the match; the flip forfeits them.
- **First player is computed on-chain at `accept_match`** (when the
  opponent joins), so light/dark is known before setup. `confirm_roster`
  only starts the clock with that side to move. See §13.
- A player can never be immobilised at setup: the empty squares are a strict subset of
  the 27-square block, so at least one empty square is orthogonally adjacent to a
  friendly piece, which therefore has a legal move

## 4. Movement

- **One piece per turn**
- One square, **orthogonally only** — forward, backward, or sideways
- **Diagonal moves are ILLEGAL**
- Moves of more than one square are illegal
- **Friendly squares are strictly blocked.** No stacking, no passing through, no
  self-challenge.
- Cannot move off the board
- **A piece MAY return to the square it just left.** No no-retreat rule.
- No other movement restrictions. No piece moves differently, no special first move,
  no castling analogue.
- Diagonals being illegal means a piece does **not** threaten a diagonally adjacent
  enemy. Diagonal adjacency is safe.
- The Flag moves like any other piece
- No passing — a piece must move

**Why the friendly-square rule is not negotiable.** "No other restrictions" is a
translation artefact meaning *any orthogonal direction*, not *any square*. Three
structural reasons: a challenge is defined as entering an occupied square and you
cannot challenge your own forces; one piece per square is physical; and self-collision
would force the contract to resolve a challenge against itself, which it has no rank
knowledge to do.

## 5. Move resolution order

Strict order. Do not reorder. A quiet move (empty square, not a Flag on the
enemy home row) finishes in the move transaction. A challenge — or a possible
Flag on the enemy home row — pauses in `WaitingForArbiter`; steps 2–5 finish
when both players report.

1. **Legality** — reject if out of bounds, diagonal, >1 square, or onto a
   friendly-occupied square.
2. **Challenge** — if the target is enemy-occupied, enter `WaitingForArbiter`,
   **pause both clocks**. Players run 1-of-15 OT off-chain, then both
   `resolve_challenge` with the same `Exchange`. Ranks stay hidden.
   **Before anything else.**

   **On any elimination, the position history resets to empty.** A removed piece makes
   every past layout physically unreachable, so no earlier key can ever recur. The
   post-capture position is occurrence one by construction. This also keeps the history
   array bounded and purges dead hashes rather than leaving them to be scanned.

3. **Repetition** — append the position key, then draw if it is the third occurrence
   (§8.2). Runs in the same transaction as the posted `Exchange`, after the board
   is updated.
4. **Breakthrough** — if the mover survived and now stands on the opponent's
   home row (row 8 for A, row 1 for B), both players `confirm_arrival`
   (empty-square arrivals included). Then enter `Breakthrough`. Not an
   immediate win. See §7.2.
5. **Immobilisation** — check the incoming player for legal moves; if none, they lose
   (§7.4).

Repetition and breakthrough are **mutually exclusive**, and the ordering is what
guarantees it. A `Breakthrough` is a transient single-turn window that forces an
immediate reactive move, so it can never survive long enough to reach a third
occurrence. Because the repetition check runs directly before the breakthrough check,
any loop is structurally terminated before the breakthrough branch can open.

## 6. Challenge resolution

Order of checks matters: FLG first, then SPY, then the numeric ladder.

| Attacker | Defender | Result |
|---|---|---|
| FLG | FLG | **Challenger wins the game** |
| FLG | Any non-FLG | FLG eliminated, defender holds |
| Any non-FLG | FLG | FLG eliminated, challenger survives |
| SPY | SPY | **BOTH eliminated** |
| SPY | Any officer (SGT → 5*G) | Officer eliminated, **SPY survives** |
| SPY | PVT | SPY eliminated |
| PVT | SPY | SPY eliminated |
| Higher rank | Lower rank | Defender eliminated, attacker advances |
| Lower rank | Higher rank | Attacker eliminated, defender holds |
| Equal rank | Equal rank | BOTH eliminated (a "split") |

> **Two rows your priors will get wrong.** Equal ranks are a mutual kill *except*
> FLG-vs-FLG, where the challenger wins the game instead of both dying. And the SPY is
> **reusable** — it survives winning against any officer, so only PVT ever removes it.
> A SPY is not a single-use trap.

**Positional outcomes — the attacker always advances into the contested square on a
win.**

- Attacker wins → defender removed, **attacker occupies the target square**
- Defender wins → attacker removed, defender holds
- Split → both removed, **target square left EMPTY**

Notes:

- **Any piece can eliminate the FLG**, including the opposing FLG.
- **A challenged FLG loses the game immediately** for its owner.
- The contract removes the losing piece from occupancy without publishing
  its rank. Players never prove a piece mid-game.

**Consequence for the FLG.** The FLG loses to every other piece, so an FLG moving onto
an *occupied* square is always eliminated — unless the defender is the enemy FLG, in
which case the moving FLG wins outright. **The FLG can only reach the home row by
stepping onto an empty square.**

## 7. Win conditions

### 7.1 Capture the enemy Flag
Any piece challenging the enemy FLG removes it. The owner loses.

### 7.2 Flag breakthrough
Arrival on the opponent's home row does **not** win immediately. It opens a survival
buffer:

- Set `Breakthrough { by, at }`. The turn passes to the opponent.
- The opponent gets exactly one turn, on their remaining game clock.
- If their next move **targets `at`** → challenge → any piece beats the FLG → FLG
  eliminated → **opponent wins** (`FlagCaptured`).
- If their move goes **anywhere else** → **breakthrough player wins**
  (`FlagBreakthrough`).
- If they are **immobilised** or **time out** → breakthrough player wins
  (`FlagBreakthrough`).

Arrival is always onto an empty square (§6), so the buffer is the only thing between
the FLG and victory. It forces the FLG player to clear the landing square *and* its
orthogonal neighbours, or gamble that the opponent won't spend their one turn there.

**What is public.** Occupancy shows a piece on the far rank; the UI must
**not** name Flag or breakthrough. Dual `confirm_arrival(is_flag)` reports
agree privately via the mailbox. A breakthrough survives only if the reply
does not challenge that square (or the opponent times out / is immobilised).

**Client requirement.** Persist the piece→salt mapping locally. Both
players `confirm_arrival`; neither attaches a mid-game rank proof. Home-row
confirm looks like any other quiet move; the reply turn looks like any
other turn. Only when the match ends with `FlagBreakthrough` is the Flag
flipped and the win declared.

### 7.3 Resignation

### 7.4 Opponent immobilised
If, after any move, the incoming player has **zero legal moves**, they lose
immediately. Reason is `Immobilised`, or `FlagBreakthrough` if a `Breakthrough` is
pending.

- Not a draw. A deadlock only draws via §8.
- Not a pass. A pass would let a player wall off lanes with an immovable cluster.
- Only the incoming player can be newly immobilised; the mover can always reverse.
- **Checked after the repetition check, and the two can never both fire.** An identical
  position key means identical board *and* side to move, so an immobilised player at
  occurrence three was already immobilised at occurrence one and the game would have
  ended there.

> ### IMPLEMENTATION NOTE — early exit is mandatory
> The legality scan must terminate the instant a single legal move is found for any
> piece belonging to the incoming player. Do not scan the whole side.
>
> ```rust
> for piece in incoming_side.pieces() {
>     for sq in orthogonal_neighbours(piece.square) {
>         if sq.in_bounds() && (sq.is_empty() || sq.is_occupied_by(active_side)) {
>             return; // still InProgress
>         }
>     }
> }
> // zero legal moves -> Ended { Immobilised | FlagBreakthrough }
> ```
>
> A legal destination is **empty or enemy-occupied** — friendly-occupied is blocked
> (§4). Testing only for empty squares wrongly declares a player immobilised when their
> only move is a challenge. The common case exits after ~4 neighbour checks; the full
> scan only runs when a player genuinely is boxed in.

## 8. Draw conditions

### 8.1 Draw offers
A draw offer is legal **only from the active player, on their own turn, before they
execute a move.** Off-turn offers are strictly illegal — permitting them invites race
conditions and griefing against the turn holder.

- At most one live offer at a time. The active player may overwrite an existing offer
  with a fresh one.
- The opponent may accept at any moment while the offer is live.
- **An unanswered offer expires the instant the opponent submits a legal move.** The
  offerer's own move does not clear it, so the opponent gets a real window to decide.
- A live offer never blocks movement.

An immobilised player never gets a turn, so §7.4 beats agreement.

### 8.2 Threefold repetition
Draw if the **exact same position key occurs three times**.

```
position_key = sha256(borsh(square_occupancy[72], side_to_move))
```

- `square_occupancy` is the **complete** 72-entry coordinate array: one byte per
  square, `0` empty, `1..=21` player A's pieces by index, `22..=42` player B's by
  index. Order is the array, not a map, so two identical layouts always hash
  identically.
- **`side_to_move` is combined in explicitly.** Identical layouts on different turns
  are different positions — one player retreating under pressure is not the same state
  as the other pressing. Omitting it fires false draws.
- Piece identities are known to the contract without knowing ranks, so the key needs
  no reveals.
- **Automatic.** Append a key per move and resolve on the third occurrence.
- **History resets to empty on any elimination** (§5 step 2). After a capture the
  current position is occurrence one.

## 9. Post-game settlement

Settlement is detached from gameplay. `Ended` is terminal for play; the
settlement status is a separate field. There is no settlement screen. The
client sends both setups automatically when the whistle goes. Both players
then see the real board and the eliminated pieces.

Kickoff does not enforce the 42-count (§3). This step **opens the hashes**
and checks that the published list matches the stored commitments, then
`COMPOSITION` and the fight log. Re-hashing is the check.

```
SettlementStatus =
  AwaitingFlip { deadline }
| Settled
| Forfeited { by: Side }
| Voided
```

**Trigger.** `Ended` opens `AwaitingFlip` with a deadline of **5 minutes**.
This is after the game. It is not taken from either player's clock. The
timeout exists only if the automatic send fails.

**Action.** The client calls `submit_setup(match_id, pieces)` with
`Vec<(Rank, file: u8, board_rank: u8, salt: [u8;32])>` — all 21 pieces in
original index order. Retry is allowed inside the window if the payload is
malformed.

**Storage.** The contract cannot invert SHA-256. `submit_setup` stores the
claimed 21-piece plaintext for the window (so the UI can flip), hashes each
row, and compares it to the commitment on that square. There is no
`verify_setup` oracle. The plaintext is dropped after the check.

**Resolution.**

| Outcome | Settlement status |
|---|---|
| Both pass | `Settled` — transfers follow §10; board is public |
| One fails or times out | `Forfeited { by }` — the other takes the stake **regardless of who won the board** |
| Both fail or both time out | `Voided` |

**Void.** Recorded as `Void { MutualSettlementFailure }`. Excluded from win/loss
counts, both players take the ladder penalty (§11), and any stakes are retained
(§10).

**Both sides are checked**, including the player who already lost the board.
That is how a clean draw can refund both stakes, and how a double failure
becomes a void. Do not delete the second check.

## 10. Financial escrow and protocol penalties

**Free-to-Play is the system default.** Token stakes are strictly opt-in, configured
manually at match creation. `stake: U128` where `0` means free. Escrow is decoupled
from standings, records, and Elo: the core loop must run with zero token movement, and
every function must handle a zero-value deposit.

**All transfers are gated on `Settled`.** No payout before settlement.

**Rake: 1.5% (`RAKE_BPS = 150`), taken from any staked pot that changes hands.** No
rake on a draw or a void, since nothing transfers.

| Outcome | Free match | Staked match |
|---|---|---|
| Win | no-op | winner takes both stakes **minus rake** |
| Clean draw, both pass | no-op | **100% symmetric refund**, no rake |
| Forfeiture | no-op | the honest player takes both stakes minus rake |
| Void | no-op | both stakes **retained by the contract** |

**Stake retention is protocol revenue.** On Both-Fail the escrowed stakes are
**permanently retained by the contract treasury, never burned.** No transfer, no burn
address, no external config.

**Revenue (when stakes / vault ship) is protocol-side:** rake on staked
matches, retained voided stakes, and (if a free pool exists) surplus Pro
allowance. See `docs/FINDINGS.md` F4. v0.1.0 does not pay call bounties.

## 11. Asynchronous Elo ladder module

Rating lives in the **separate registry contract** (§16) and is applied at settlement,
never at `Ended`.

**Decoupled architecture.** The match contract makes **zero outbound cross-contract
writes**. On settlement it updates its own state, executes transfers, and emits
`MatchSettled` / `MatchVoided`. The registry consumes that finalised state through a
permissionless call — `registry.apply_result(match_id)` — which reads the
match's terminal settlement status and applies the delta. A registry panic therefore
cannot fail a settlement; a dead registry stalls the ladder and nothing else.

**Ladder finality.** Standings stay frozen and provisional until the settlement window
closes. The front end MUST NOT display definitive rating deltas the moment the board
game ends — the board outcome is provisional and the settlement outcome is
authoritative. A player who achieves a breakthrough and then fails verification
forfeits, and the honest player takes the full victory points despite having "lost" the
board.

**Rating boundary clamping (required).** No path — standard, forfeit, or void — may
take a rating below `RATING_FLOOR`. On a transfer (standard or forfeit) the recipient
gains exactly what the payer could legally lose:

```rust
let loss = cmp::min(computed_loss, payer_rating - RATING_FLOOR);
// transfer exactly `loss`
```

Without this, every match at the floor mints phantom points and the ladder inflates.
A void clamps each side independently: `new = max(FLOOR, rating - VOID_PENALTY)`.

**Configuration.** Locked. Retuning any of these is a registry redeploy, not a live
knob.

```rust
pub const START_RATING: u32 = 1200;
pub const RATING_FLOOR: u32 = 25;         // Absolute backstop
pub const K_FACTOR_VOLATILITY: u32 = 48;  // Absorbs hidden-state and bluffing variance
pub const FIRST_MOVE_ADVANTAGE: u32 = 50; // Offsets aggressive opening traps for Player 2
pub const FORFEIT_PENALTY: u32 = 55;      // Zero-sum flat transfer, kills favourite-forfeit
pub const VOID_PENALTY: u32 = 55;         // Symmetric Both-Fail deduction, deflationary
pub const RATING_SCALE: u32 = 10_000;     // 1.0 expected score; wasm integer only
pub const RATING_DIFF_CLAMP: u32 = 800;   // |R_first + ADV - R_second| cap
```

`K = 48` sits deliberately above chess convention: hidden information makes upsets
cheap, and a steeper K lets the ladder track tactical adaptation rather than smoothing
a lucky guesser into a stable mid-table rating. `ADV = 50` is likewise elevated —
moving first dictates the pacing of the middle-game clash and the placement of traps.
`R_first` / `R_second` are the **kickoff colours** bound at `accept_match`, not the
side that moved last.

**Invariant: `FORFEIT_PENALTY > K_FACTOR_VOLATILITY`.** After the integer rounding
below, the maximum loss from a standard match is exactly `K` (a heavy favourite
losing at the ±800 clamp). If the forfeit penalty is lower, a favourite in a lost
position can profit by deliberately failing settlement.

**Invariant: `VOID_PENALTY >= FORFEIT_PENALTY`.** A player who has already failed
settlement must not improve their own rating by also blocking the opponent (void
instead of solo forfeit). Equality is allowed: own-score indifferent, opponent still
hurt. A smaller void is a grief incentive. Assert both invariants in tests.

### Standard formula (Win and Draw)

Real-valued Elo, for intuition only. The contract never evaluates this.

```
E_second = 1 / (1 + 10^((R_first + ADV - R_second) / 400))
E_first  = 1 - E_second
R'       = R + K * (S - E)
```

`S` is 1 / 0.5 / 0 for win / draw / loss. The second player is compensated for the
structural disadvantage: more for a win, less for a loss, and a draw transfers
points to them. This is per-match fairness. First player is randomised (§3), so a
miscalibrated ADV does not inflate a career — it only reallocates the game that was
just played.

### Integer algorithm (authoritative)

Wasm forbids floats. Ratings stay `u32`. One signed transfer `t` is
computed from the **second** player's view; first gets `-t`. Then the floor clamp
shrinks `|t|` if needed. Never round the two sides independently — that is how
+21 / −20 enters the ladder.

```
S_second   = RATING_SCALE | RATING_SCALE/2 | 0   // second win | draw | loss

d = clamp(R_first + ADV - R_second, -RATING_DIFF_CLAMP, RATING_DIFF_CLAMP)
e = EXPECTED_SECOND[d + RATING_DIFF_CLAMP]   // parts per RATING_SCALE
raw = K * (S_second - e)                    // i64
t = div_round_half_away(raw, RATING_SCALE)  // i32, toward-zero after bias
```

`div_round_half_away` is half away from zero, then **toward-zero** quotient (Rust
`i64` `/`, not Python floor-div):

```rust
fn div_round_half_away(n: i64, d: i64) -> i32 {
    let q = if n >= 0 { (n + d / 2) / d } else { -(((-n) + d / 2) / d) };
    q as i32
}
```

`EXPECTED_SECOND` is 1601 `u16` values, `d ∈ [-RATING_DIFF_CLAMP, RATING_DIFF_CLAMP]`,
generated **once** on a host and committed like `MATRIX`. Wasm never uses floats.
Generation rule:

```
EXPECTED_SECOND[d + RATING_DIFF_CLAMP] = round_half_away(RATING_SCALE / (1 + 10^(d / 400.0)))
```

Do not regenerate unless a locked constant above changes. `E_first` is not stored:
it is `RATING_SCALE - e` by construction, so the two expectations always sum to 1.

`RATING_DIFF_CLAMP = 800` makes the extreme expected score 99 / 9901 (about 1%). A
larger gap changes `K * ΔE` by less than half a point, which the integer step
already cannot see. At that clamp a heavy favourite who loses pays exactly `K = 48`.

**Worked example** — equal 1200/1200, `d = 50`, `e = 4285`:

| Result | `S_second` | `t` | first | second |
|---|---|---|---|---|
| Second wins | 10000 | +27 | −27 | +27 |
| First wins | 0 | −21 | +21 | −21 |
| Draw | 5000 | +3 | −3 | +3 |

Those three rows are the test vectors. The real-valued figures (+27.4 / +20.6 / +3.4)
are commentary only.

### Forfeiture — bypasses the formula

Clock timeout, resignation, immobilisation, capture, and breakthrough are **standard
wins**, not forfeits. Forfeit is protocol failure only: `WinReason::OpponentForfeited`
(`InvalidSetup` or `SettlementTimeout`).

A **flat, zero-sum transfer of `FORFEIT_PENALTY`**, then the floor clamp. No
expectation; rating gap irrelevant. Flat rather than scaled so abandoning the
protocol stings the same whether you were favourite or underdog, and so the
transfer stays zero-sum.

### Void — both at fault

Both take a flat `VOID_PENALTY`, each clamped to the floor. Deliberately **not**
zero-sum: both failed, so a full void sheds 110 points. A point sink is acceptable
for an extreme anomaly and makes breaking the audit trail never free. Excluded from
win/loss counts.

### Outcome routing

| `Outcome` | Rating effect |
|---|---|
| `Win` with `FlagCaptured`, `FlagBreakthrough`, `Resignation`, `Immobilised`, `Timeout` | standard integer formula |
| `Draw` (`Agreement`, `Repetition`) | standard integer formula, `S_second = 5000` |
| `Win` with `OpponentForfeited` | flat ±`FORFEIT_PENALTY`, then floor clamp |
| `Void` | flat `VOID_PENALTY` each, independently floor-clamped; no W/L |

Free and staked matches rate identically.

## 12. State machine

`MatchId = u64`, monotonic, assigned from a `next_match_id` counter.

```
Created -> Committed -> InProgress
InProgress  -> WaitingForArbiter -> (both players report Exchange) -> InProgress | Breakthrough | Ended
InProgress  -> Breakthrough -> (opponent response) -> Ended
InProgress  -> Ended        (capture, immobilisation, resignation, timeout,
                             agreement, repetition)
```

`Committed` requires both 21-piece hash lists and a `confirm_roster`. Player
clocks pause in `WaitingForArbiter`. A mute report forfeits after five
minutes (`claim_resolution_timeout`). There is no platform worker.

Every non-terminal **player** state still carries a clock deadline so anyone
can call `claim_timeout`. `WaitingForArbiter` does not run player clocks.

```
Ended { outcome: Outcome }

Outcome =
  Win { winner: Side, reason: WinReason }
| Draw { reason: DrawReason }
| Void { reason: VoidReason }

WinReason     = FlagCaptured | FlagBreakthrough | Resignation | Immobilised
              | Timeout | OpponentForfeited(ForfeitCause)
ForfeitCause  = InvalidSetup | SettlementTimeout
DrawReason    = Agreement | Repetition
VoidReason    = MutualSettlementFailure
```

## 13. Arbiter procedure (Option 2)

`arbiter.rs` is a **pure table** shared by contract and client:
`resolve(attacker, defender) -> Exchange`. It has no key, no board, and no
network. There is **no Arbiter worker** and **no platform decrypt key**.

The match state name `WaitingForArbiter` is historical: it means both
players must report (`resolve_challenge` / `confirm_arrival`). It does
not mean an external service is waiting. See `docs/ALTERNATIVES.md`.

There is **no Merkle surface**. No mid-game proof, no `reveal_piece`. Each
piece is `sha256(rank_id || salt)` (32 bytes) stored on its square.
`COMPOSITION` is checked **on-chain at `submit_setup`**, not at kickoff
(`FINDINGS.md` F2). Kickoff 42-count is gone with the worker.

**Who may speak.** Either player `confirm_roster` after both committed.
Either player `resolve_challenge` / `confirm_arrival`; the contract applies
only when the two reports match. A mute side forfeits after five minutes
(`claim_resolution_timeout`). Disagreement voids.

**Commitment.** Plaintext is 33 bytes: `rank_id: u8` || `salt: [u8;32]`.
Hash with SHA-256. The contract stores the 32-byte digest. Ranks stay on
the device. Do not seal to a platform decrypt key.

**Setup.** Each client submits
`commit_setup(match_id, Vec<(file, board_rank, commitment)>)` for its home
squares. Either player then `confirm_roster`. Occupancy is piece indices,
not ranks.

**First player.** Computed in `accept_match` (both accounts known), so
clients can paint light = first / dark = second during setup:

```
seed = sha256(
    env::random_seed()
    || match_id.to_le_bytes()
    || creator.as_bytes()
    || opponent.as_bytes()
)
first = if seed[0] & 1 == 0 { creator } else { opponent }
```

`confirm_roster` reuses `m.first` and sets `to_move`. Do not use a client
timestamp. Legacy matches without `first` still roll once at confirm.

**Play.** Positions public, ranks hidden. A challenge enters
`WaitingForArbiter` (dual-player report wait). Both run OT — or
local `resolve` on one device — and report. Home-row arrival is the same
two-report path with `is_flag`.

**End.** Each player `submit_setup` with `(rank, file, board_rank, salt)`.
The contract checks the hash, home squares, `COMPOSITION`, and replays
the fight log against the openings. A row that does not match the
recorded `Exchange` fails that attacker’s verify (Alice’s Five-star).

**Mailbox.** `scripts/mailbox_local.mjs` carries OT ciphertexts and
display-only clock notes. It must not hold a match secret. If it dies,
players can OT on another channel.

**Self-reveal mid-match is out of scope.**

### Signed moves

`SignedMove` is `{ match_id, from, to, nonce: u64, signature }`. NEP-413,
verified **inline** in `apply_moves`. The contract stores `next_nonce` per
side per match and rejects anything else. Do not hash the nonce first — that
is an extra hop with no gain.

## 14. Match parameters

Chess-style sudden-death bank. No increment. No per-move reset. No casual or
blitz preset. Client/chain sync and display are in [`CLOCKS.md`](CLOCKS.md).

The match **creator** sets each player's clock at `create_match`: a whole
number of minutes from **1 to 15 inclusive**. Both players receive that same
bank. The opponent sees it before `accept_match`. It cannot be changed after
creation.

`create_match(opponent, stake, ruleset, clock_minutes: u8)`.
Reject `clock_minutes < 1` or `clock_minutes > 15` (`InvalidClockMinutes`).
Store nanoseconds:
`clock_minutes * 60 * 1_000_000_000`. Integer arithmetic only. Each side's
remaining time starts equal to that value.

| Parameter | Value |
|---|---|
| Game clock | 1–15 minutes per player, chosen by the creator |
| Whose clock runs | the side to move, for the time the turn was on their screen (see below) |
| Network credit | at most 5 s per move (`LAG_CAP_NS`) |
| Waiting for both reports | both clocks paused |
| After the game | 5-minute automatic flip; timeout only if that send fails |
| Move cap | none |

**No turn grace.** After `confirm_roster` and after every turn handoff, the
turn starts at the block (`turn_started_at`). Both phones read one
`get_sync` row. See [`CLOCKS.md`](CLOCKS.md).

**During play.** `apply_moves` takes an optional `think_ns`: how long the
turn was on the mover's screen before they tapped. With `elapsed` the turn's
length block to block, the mover is charged
`clamp(think_ns, elapsed - LAG_CAP_NS, elapsed)`, `LAG_CAP_NS` = 5 s; without
`think_ns`, all of `elapsed`. The opponent's turn then starts at the block,
so network time is charged to nobody, up to 5 s per move. The claim is
untrusted: it can save at most 5 s per move.

If remaining hits zero before a legal move, that player loses (`Timeout`).
`claim_timeout` is accepted once `elapsed >= remaining + LAG_CAP_NS`, so a
move tapped just before the flag can still land. A breakthrough reply uses
the same bank: the opponent has whatever they have left, not a fresh timer.

**During a challenge.** Clocks pause. Both players report the 2PC result.
Play continues. Nobody proves a rank.

**After the game.** Clocks do not run. The client flips the board
automatically. The 5-minute window is only a safety net.

## 15. Illegal move handling

- Illegal moves rejected, turn does not advance, the mover's clock keeps running
- Client validates locally; contract is authoritative
- A player who never moves loses on timeout once their bank has been at zero for 5 s (`LAG_CAP_NS`)

## 16. Contract topology

**The contract set is fixed: match, registry, and vault. Never a
contract per match.** (Only the match account is live on testnet.)

**Match contract** owns matches, escrow, and settlement. It applies an
`Exchange` only after both players report the same one. It never decrypts.
No outbound cross-contract calls; no registry knowledge.

**Every move is a transaction.** Repetition (§8.2), immobilisation (§7.4), and
breakthrough (§7.2) all need per-move state, so moves cannot live off-chain.
The **player submits and pays** gas. Per-move transactions are the dominant
cost. See `docs/FINDINGS.md` F1 and `docs/ECONOMICS.md`.

**Registry contract** owns the ladder, profiles, and all rating constants. Consumes
match events via the permissionless `apply_result` call described in §11. It
runs the integer algorithm in §11 — one transfer `t`, baked `EXPECTED_SECOND`, no
floats.

Registry guards:
- Store the single authorised match contract account at init and read only from it —
  `match_id` is unique only within a contract, so an arbitrary account lets anyone
  spoof results
- `applied[match_id]` idempotency flag — two callers can race
- Refuse anything not in `Settled` / `Forfeited` / `Voided`
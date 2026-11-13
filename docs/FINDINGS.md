# FINDINGS.md

**v0.1.0.** These dead ends still bind the current cut (no Merkle, on-chain
moves, integer Elo clamp).

Negative results from building Engkwentro. Each cost real time to discover and is
written so the next builder doesn't rediscover it.

## F1. Challenges-only-on-chain does not work for turn-based games

**Observation.** The obvious cost optimization is to keep moves off-chain and put only
challenges on-chain. It fails. Repetition detection needs a position key per move,
immobilization needs a post-move board scan, and breakthrough needs a per-move state
transition. All three require the contract to see every move.

**Cost if ignored.** You build the off-chain path, then discover the arbiter can't
detect draws or immobilization, and rewrite to on-chain moves. Our projection went
from $0.03 to $0.14 per match — a 5× miss.

**Fix.** Accept every move on-chain. Do not drop per-move state. Multi-move batching stays out of scope for v0.1.0 (`apply_moves` is exactly one move).

## F2. A Merkle root cannot verify composition

**Observation.** A root over 21 leaves constrains each leaf's hash path and nothing
else. Nothing binds `rank_id` to a count. A modified client commits three Spies and no
Sergeant and the contract cannot tell — not on reveal, not ever.

**Cost if ignored.** The one thing players agree to before the first move is the one
thing the chain can't audit.

**Fix.** Do not use a Merkle root. Each piece is a hash commitment
`sha256(rank || salt)` the contract can open. `COMPOSITION` is checked
on-chain at `submit_setup`, not inferred from a tree. Kickoff 42-count
needs a god-view (the old worker) or a ZK proof (Option 1); Option 2
accepts the flip as the composition audit. Still no `merkle.rs`.
See `docs/ALTERNATIVES.md`.

## F3. An unpriced withholding surface wedges the state machine

**Observation.** Interactive reveal means a player can stall by not submitting a proof.
The naive penalty — award the challenge to the revealer — is wrong, because without the
withholder's rank the contract *cannot compute the challenge outcome*. It can only
guess.

**Cost if ignored.** A permanently unresolved event in the match log, in a system whose
entire premise is verifiability.

**Fix.** Mid-game reveal is gone. A fight is 2PC (or local `resolve` on one
device); both players report the same `Exchange`. Withholding is a
**resolution timeout** (mute side forfeits) or a settlement failure on the
flip. Still flat and zero-sum, priced above a worst-case loss. See
`docs/ALTERNATIVES.md`.

## F4. Staking yield is a poor revenue base for high-frequency usage

**Observation.** At ~$0.14/match and ~$3.13/month of yield per 250 NEAR stake, a daily
free tier runs ~20× underwater at 6% conversion and ~135× at 1%. Yield scales with
stake, cost scales with play frequency, and they diverge.

**Cost if ignored.** You model break-even on a revenue source that is structurally an
order of magnitude too small.

**Fix.** Free rate driven by pool health, not a fixed number. Batching to $0.04 cuts
break-even conversion ~57% → ~28%.

## F5. Repetition and immobilization are mutually exclusive and ordering matters

**Observation.** Both are post-move board checks. They can never both fire: an
identical position key implies identical board *and* side to move, so a player
immobilized at the third occurrence was already immobilized at the first and the game
would have ended there. Checking immobilization first would still be correct but
unreachable; checking repetition first makes the exclusion structural.

**Fix.** Fixed order — repetition, then immobilization — with the reasoning written
down so it isn't "cleaned up" later.

## F6. Zero-sum breaks at a rating floor without clamping

**Observation.** A player at the floor cannot pay a full loss. Without clamping the
winner still gains the full amount and the ladder inflates on every floor match.

**Fix.** `loss = min(computed_loss, rating - FLOOR)`; transfer exactly that.

## F7. Independent Elo rounding breaks zero-sum

**Observation.** `R' = R + K(S − E)` on each side is zero-sum in the reals. Rounding
each side to an integer is not: equal 1200s, first-player win, becomes +21 and −20
if you `round` twice. The ladder then mints or burns a point per game.

**Fix.** Compute one signed transfer `t` from the second player's view; first gets
`−t`. Floor-clamp that same `t`. Wasm is integer-only (`SCALE = 10_000`, half-away,
toward-zero quotient). See `RULES.md` §11.

## F8. A void cheaper than a forfeit is a grief

**Observation.** Solo settlement failure costs `FORFEIT_PENALTY`. Mutual failure
costs `VOID_PENALTY` each. If void < forfeit, the player who already failed should
block the opponent so they pay −25 instead of −55. `config.rs` shipped `VOID = 25`
against a spec of 55.

**Fix.** `VOID_PENALTY >= FORFEIT_PENALTY`. Equality is the lock (55 / 55). Assert it.

---

## F9. Alice’s Five-star is deferred, not closed

**Observation.** Option 2 cannot stop a hostile client feeding a fake rank
into OT. Occupancy ≠ rank; the honest `ot.dart` is not a security
boundary. The flip slashes after `Ended`.

**Status.** Accepted for this cut (2026-11-01). Next iteration: bind the
OT row to `sha256(rank || salt)` (Option 1 or equivalent). Not mid-game
reveal, not a platform decrypt key. See `ALTERNATIVES.md`.

---

## Transferable artifacts

1. Cheap non-ZK hidden-state pattern for static hidden-information games
2. Retroactive input audit for any commit-then-play protocol
3. Arbiter as a shared pure function with an exhaustive matrix
4. Operator-death survivability via permissionless timeout / settle calls
5. This document
6. A specified Phase 2: batching ($0.14 → $0.04) and fiat-priced Pro at $2/month
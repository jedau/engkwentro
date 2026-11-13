# ARCHITECTURE

**v0.1.0 playable MVP.** Match setup, play, and settlement are implemented.
The Flutter client plays two-phone testnet
(`play.engkwentro.testnet`); the home screen has no local pass-and-play.
Vault and registry crates compile; they are not on the live play account.
See `docs/CLIENT.md`.

## Overview

Three contracts, each with one job and no ability to fail another.

| Contract | Owns | Calls out |
|---|---|---|
| match | matches, escrow, settlement | **nothing** |
| registry | ladder, profiles, rating constants | reads match (view) |
| vault | staking, Pro entitlement, allowance, free pool | nothing |

The rule that holds the system together: **the match contract makes zero outbound
cross-contract calls.** Everything it needs to finish a match it already has.

## Why three, and not one

Settlement is authoritative for both money and rating. If the rating write lived in
the match contract, a registry bug would be a settlement bug, and settlement bugs cost
funds.

Splitting them means a registry panic stalls the ladder and nothing else. Matches
still resolve, money still moves, and the ladder catches up when the registry does.

## Why not a contract per match

A per-match contract means a deploy per match. Deploy cost and state size both scale
with concurrency, and every match becomes its own upgrade and discovery surface.
Matches are sub-state keyed by `MatchId` in one contract instead.

## Why the table is shared, and decrypt is not on-chain

`arbiter.rs` is a **pure function** — `fn resolve(attacker, defender) -> Exchange`,
no storage, no `env`, no `self`. That keeps the 225-pair matrix honest and lets
the client import the same table (`client/lib/arbiter.g.dart`).

A public contract cannot hold ranks. Each player holds their own. A fight
is 2PC (1-of-15 OT) plus two reports. The contract stores
`sha256(rank || salt)` and applies `Exchange` only when both reports
match. Composition is checked on the flip, on-chain.

## Data flow

**Setup.** First player is the SHA-256 bit at **`accept_match`**. Each
client arranges its 21 pieces, commits 21 hashes on home squares, then
either player `confirm_roster` → occupancy from positions → `Committed`
with that side to move. No platform decrypt key.

**Gameplay.** The player signs and submits `apply_moves` (predecessor;
NEP-413 fields empty when the caller is that player). A challenge or
home-row step enters `WaitingForArbiter` → both players report the same
`Exchange` / arrival → board updates, ranks stay hidden.

**End.** Each `submit_setup` opens 21 salts. The contract checks hashes,
`COMPOSITION`, and the fight log. The UI shows the board and the graveyard.

**Rating.** Settlement resolves → anyone may call `registry.apply_result(match_id)` (when deployed) →
registry reads the match's terminal settlement state → applies the integer Elo in
`docs/RULES.md` §11. One signed transfer `t` from the second player's view (kickoff
colours, not the last mover). Floor clamp on standard, forfeit, and void. No floats.

## State machine

```
Created -> Committed -> InProgress
InProgress  -> WaitingForArbiter -> (both players report Exchange) -> InProgress | Breakthrough | Ended
InProgress  -> Breakthrough -> (opponent response) -> Ended
InProgress  -> Ended        (capture, immobilisation, resignation, timeout,
                             agreement, repetition)
```

Player clocks pause in `WaitingForArbiter`. A mute report is a timeout
forfeit, not a platform restart. Clients read one `get_sync` row per
refresh and charge think time via `apply_moves(think_ns)`:
[`CLOCKS.md`](CLOCKS.md).

`Ended` is terminal **for gameplay**. The settlement layer is a separate field on the
match record and the arbiter never reads it.

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

## The settlement layer

```
SettlementStatus =
  AwaitingFlip { deadline }
| Settled
| Forfeited { by: Side }
| Voided
```

Detached deliberately. If it were a state variant, the arbiter would have to know about
post-game concerns and every terminal transition would need a settlement branch.

The client sends this automatically. The 5-minute window is only if that send
fails. `submit_setup` checks each `sha256(rank || salt)` against the stored
commitment, then `COMPOSITION` and the fight log. Re-hashing is the check
(the old sealed-box path was not deterministic). Both sides are checked,
including the player who already lost the board.

**The loser is verified even when the win is already awarded.** Needed for the
public board flip, void detection, and a clean draw refund.

## Permissionless calls

`claim_timeout`, `claim_resolution_timeout`, and `settle` may be called by
**any account**. There is no cranker service and no operator key. In v0.1.0
the caller pays gas (no bounty payout is wired).

`registry.apply_result` is the same idea for the ladder once the registry
is deployed; it is not on the play path today.

These calls are safe to race: each is idempotent on the match record.

## Storage

Matches stay in the `LookupMap` after `Ended` / settlement (needed for
`get_outcome`, `get_opened`, payouts). Storage on NEAR is a refundable
deposit; reclaiming resolved matches is future work, not v0.1.0.

The position-history vector is cleared on any elimination, keeping it
bounded and purging dead hashes. The fight log is retained for the flip.

## Failure matrix

| Failure | Effect |
|---|---|
| OT mailbox down | Players switch channel; report window still runs |
| Mute report | That side forfeits after five minutes |
| Disagreeing reports | Match voids |
| Nobody calls timeouts | Any account can still `claim_timeout` / `settle` |
| Registry down | Ladder stalls; settlement and payouts unaffected |
| Vault down | Pro entitlement stalls; free and staked matches unaffected |
| Auto-flip send fails | Retry inside the 5-minute window |
| Illegal roster | Match starts; flip forfeits the liar |
| RPC / network stall | Client deadlines + retry; pending move keeps the overlay up |

A dead mailbox does not stop a match if the two players can still reach
each other.

## Gas shape

Cost is dominated by one transaction per move, because per-move state is required by
repetition, immobilisation, and breakthrough. In v0.1.0 `apply_moves` accepts
**exactly one** move (plus optional `think_ns`). Multi-move batches are out of scope.

## Rejected alternatives

**ZK per turn.** Correct and expensive. Rejected on latency and mobile viability, not
on soundness.

**Mid-game Merkle reveal.** Leaks ranks, cannot check composition (`FINDINGS.md`
F2), and opens a withhold stall. Dropped. No `merkle.rs`.

**Platform decrypt key.** Replaced by Option 2 (`docs/ALTERNATIVES.md`).
Do not put a worker SK back “for kickoff only.”

**Arbiter secret derived from player keys.** Still out — that was the
old sealed-box design. There is no match secret now.

**Challenges-only on-chain.** The obvious optimisation, and wrong — it cannot detect
draws or immobilisation. See [`FINDINGS.md`](FINDINGS.md) F1.

**Liquid staking token for the vault.** Adds an AMM, a harvest cron, and depeg basis
risk for a subscription feature. Direct staking does the job.

**Per-match contracts.** Deploy cost and surface area scale with concurrency.
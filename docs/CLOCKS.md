# CLOCKS — turn, clock and overlay authority (v0.1.0)

Rewritten 2026-11-12. This replaces every earlier clock model in this file.

## Why the earlier versions failed

They changed how clocks count and left the structure alone:

- **Four separate views per refresh** (`get_play`, `get_board_for`,
  `get_match`, `get_clocks`). They could answer from different blocks, so a
  phone painted a turn and a clock that never co-existed. That is how both
  phones showed "Opponent's turn".
- **No deadline on any request.** One stalled call held the screen for a
  minute while the local tick kept burning the mover's bank.
- **Two writers.** The poll timer and the tapped action both wrote the
  screen, in whichever order their replies came back. A late reply from an
  older block overwrote a newer one.
- **The mover paid for the network.** The bank was charged block to block,
  so the time a move took to reach a block came off the mover's clock, and
  the phone's local guess was then corrected: the rewind.
- **The overlay dropped when the transaction was sent**, not when the chain
  showed the result, leaving an idle board that looked like a lost tap.

## Model

| Concern | Source |
|---|---|
| Turn, board, banks, seats | One `get_sync` row, from one block |
| Order of rows | `block_height`; an older row is dropped |
| My running clock | Timed on this phone from when the turn appears, frozen at the tap |
| What my move costs | `think_ns` sent with the move, bounded by the contract |
| Opponent's running clock | Estimated chain time, drawn slightly behind |
| Overlay | Up from the tap until a row shows the move |
| Who talks to NEAR | One serialized loop (`MatchDriver`) |

### 1. One row, one block (`get_sync`)

`get_sync(match_id)` returns, from a single view call:

```
( play      (state, to_move, nonce_a, nonce_b, wait_from, wait_to),
  clocks    (bank_a_ns, bank_b_ns, turn_started_at_ns, chain_now_ns,
             clocks_paused, block_height),
  seats     (creator, opponent, accepted, first, setup_a_in, setup_b_in),
  occupancy [72] )
```

Banks are **as stored**: what each side had when the current turn started.
Nothing is subtracted, so every row within a turn carries the same numbers
and a running clock is `bank - (now - turn_started_at)`.

The client keeps exactly one `PlaySnap` (`session.play`). Status line, both
clocks, the board and the overlay are all derived from it. There is no
second copy of "whose turn" anywhere.

A row whose `block_height` is lower than the one already applied is dropped
(`staleDropped` counts them). The seat comes from the row every time; if the
signed-in account is neither player the session stops with an error.

### 2. The mover is charged for thinking, not for the network

`apply_moves(match_id, moves, think_ns)`.

`think_ns` is how long the turn was on the mover's screen: from the phone
first showing it to the tap. The contract knows `elapsed`, the turn's length
block to block, and charges

```
charged = clamp(think_ns, elapsed - LAG_CAP_NS, elapsed)     LAG_CAP_NS = 5 s
```

The next turn starts at the block. So the time a turn takes to reach a phone
and the time a move takes to reach a block are charged to **nobody**, up to
5 s per move. Beyond 5 s the excess is the mover's.

The claim is untrusted. The clamp means a modified client can gain at most
5 s per move and can never be charged less than `elapsed - 5 s`. Omitting
`think_ns` charges block to block, as before.

`claim_timeout` succeeds only when `elapsed >= remaining + LAG_CAP_NS`: a
move tapped just before the flag may still be in flight. A flag is therefore
claimable up to 5 s after the clock face reads 0:00.

### 3. My clock

Timed with the phone's monotonic clock from the moment the turn appears on
this screen, and frozen at the tap. The face at the tap is the bank the
chain stores afterwards (difference 0 in simulation, see below), unless the
move took more than 5 s to land.

Floor: `max(local think, chain elapsed - 5 s)`, so the face never shows more
than the contract would grant.

### 4. The opponent's clock

Their phone's clock cannot be seen from here; only the chain can, and the
chain is behind. So their running clock is drawn from estimated chain time,
a little late (`streamDelayNs`, measured, 0.3 to 3 s). When their move
lands, the face is corrected to the stored bank.

**Turn-seen note (display only).** When a phone first paints "Your turn" it
drops `seen-{side}-{turn_started_at}` in the mailbox. Until the other phone
reads that (or a tap note / the move itself), it **holds their clock face at
the bank** so the seconds before their board unlocks are not shown burning.
Never used for the turn, status, banks or timeouts.

**Tap note (display only).** On a tap the mover's phone also drops
`tap-{side}-{nonce}` holding its clock face. The other phone stops drawing
the opponent's clock when it appears. Same limits as the turn-seen note.

Turn tap notes off with `session.tapNotes = false`. Turn-seen stays on.

### 5. Overlay and status

A tap creates a `PendingMove` on the same frame. From then until a row shows
the mover's nonce advanced:

- the status line is never "Your turn",
- the overlay is up (`Battle!` for an attack, `Moving…` otherwise, with a
  small sublabel for the step in progress),
- the mover's clock is frozen.

If that row is a fight, `Battle!` stays up until both reports are in. There
is no frame between "sent" and "fight" where the board looks idle.

If NEAR never confirms: the move is resent once, watched for 8 s, then
dropped with "Your move did not reach NEAR. Try again." and the turn is the
player's again.

### 6. One driver

`MatchDriver` (`client/lib/net_driver.dart`) is the only thing that talks to
NEAR for a match. One self-rescheduling loop; user actions take the same
lock. At most one request is in flight per phone, so replies cannot arrive
out of order with each other.

| Situation | Gap between steps |
|---|---|
| Move in flight, fight open, opponent's turn, starting | 250 ms |
| My turn | 1 s |
| Match over | 3 s |

Every request has a deadline (view 4 s, transaction 10 s, mailbox 5 s) and
is retried. A single slow reply is retried silently; repeated ones show
"Connection is slow. Still trying…" once.

## Measurements

From the offline two-phone simulation
(`client/test/two_phone_sim_test.dart`): the real `NetSession` and
`MatchDriver` on both sides, a model of the contract on 600 ms blocks, and
an observer reading both screens every 50 ms. Run it with

```
cd client && flutter test test/two_phone_sim_test.dart -r expanded
```

Normal network (view round trip 0.28 to 0.44 s), 70 moves, 13 attacks:

| Measure | Tap note on | Tap note off |
|---|---|---|
| Things on screen that must never be | 0 | 0 |
| Own clock stepping up | 0 | 0 |
| Bank after move minus face at tap | 0 ms, all 70 | 0 ms, all 70 |
| Tap to overlay down | p50 1.7 s, max 2.4 s | p50 1.7 s, max 2.55 s |
| Opponent clock corrected back by 250 ms or more | 3 of 70, max 0.76 s | 8 of 70, max 1.45 s |
| Opponent clock skipping forward | p50 0.2 s, max 0.87 s | p50 0.3 s, max 0.95 s |
| Same running clock, phone vs phone | max 1.07 s | max 2.5 s |
| Same resting clock, phone vs phone | 0 ms | 0 ms |
| Both screens "Opponent's turn" | p50 0.15 s, max 0.8 s | p50 0.2 s, max 0.8 s |
| Turn start on chain to "Your turn" on screen | p50 0.7 s, max 1.35 s | same |
| Network time per move charged to nobody | p50 1.76 s, max 2.45 s | same |

Rough network (stalls, nodes answering from old blocks, lost replies and
dropped transactions), six seeds, 60 moves each: no forbidden screen state
and no own-clock step up in any run. Latency is what it is: tap to overlay
down p50 about 3.8 s, p90 11 to 15 s, worst 32 s; the opponent's clock is
corrected by several seconds; both screens can read "Opponent's turn" for up
to about 16 s while a move is in flight.

Read-only check against FastNEAR testnet from the dev machine (160
`get_sync` polls): round trip p50 0.48 s, max 0.75 s, no failures, no reply
from an older block, answered block 0.9 to 2.3 s old.

Not yet measured: a full match between two real phones on the redeployed
contract.

## Known limits

- The opponent's running clock is an estimate. Expect a correction of up to
  about a second a few times per game on a normal connection.
- Both screens read "Opponent's turn" for the time a move takes to reach the
  other phone (well under a second normally). It is true for that long: the
  mover has moved and the other phone has not heard yet.
- A modified client can gain up to 5 s per move.
- On a connection where a move takes more than 5 s to land, the excess is
  charged to the mover and their clock drops when the move confirms.
- The simulation does not model the Breakthrough reply turn.

## Code map

| Piece | Location |
|---|---|
| `LAG_CAP_NS`, `charge_until`, `charge_clock` | `contracts/engkwentro/src/play.rs` |
| `get_sync`, `apply_moves(think_ns)`, `claim_timeout` | `contracts/engkwentro/src/lib.rs` |
| `PlaySnap`, `PendingMove`, clocks, status, overlay | `client/lib/net_play.dart` |
| Driver loop and lock | `client/lib/net_driver.dart` |
| Request deadlines and retry | `client/lib/near.dart`, `client/lib/mailbox.dart` |
| 250 ms repaint only | `client/lib/net_page.dart` |
| Contract model, network profiles | `client/test/support/fake_chain.dart` |
| Bots and screen observer | `client/test/support/two_phones.dart` |

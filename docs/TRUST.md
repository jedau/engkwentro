# TRUST

**v0.1.0.** Option 2: no platform decrypt key. Players sign and submit
their own transactions. See [`ALTERNATIVES.md`](ALTERNATIVES.md).

## TLDR

The match contract is the authority. Clients may lie about OT inputs; the
flip catches that after the game. There is no mid-game decrypt key and no
required operator on the move path.

## What a player (or their client) can do

- Sign and submit their own moves.
- Report a fight `Exchange` or a home-row arrival bit.
- Resign, claim a timeout, settle, or call resolution timeout on a mute opponent.

## What they cannot do

- Change another player's signed move.
- Forge a NEP-413 signature for someone else's key.
- Alter a settlement payout outside the contract rules.
- Decrypt the opponent's ranks mid-game. There is no match private key.

## Two-party resolution

Each player holds only their own ranks. A fight is 1-of-15 OT plus two
on-chain reports. The contract applies `Exchange` only when they agree.
A mute side forfeits; disagreement voids. The local mailbox
(`scripts/mailbox_local.mjs`) carries OT blobs and display-only clock
notes. It is not an oracle.

A hostile client can feed a fake rank into OT. The flip replays the
fight log against `sha256(rank || salt)` openings. That is delayed
audit, not live-trustless (Alice’s Five-star). See `ALTERNATIVES.md`.

If the mailbox is down, players can OT on another channel. Clocks stay
paused until both report or the resolution window expires.

## Operator death

- Live demo: the player account is the predecessor and submits.
- Player-clock and resolution deadlines are callable by any account.
- `settle` is permissionless after both armies flip (or the flip window
  times out).
- No admin key sits on the move path.

## What is *not* trustless

- Matchmaking. Whoever shares a join key decides who you meet.
- Ladder display, until settlement closes. The board result is
  provisional; the settlement result is authoritative.
- The front end itself. A hostile client can generate a legal-but-bad
  move or claim a false Flag arrival (caught at flip when verification
  is complete).
- Honest clients at setup. Kickoff does not count 42 ranks. An illegal
  roster plays until the flip, then forfeits.
- Delayed fight audit. A 2PC input lie is caught after `Ended`, not live.

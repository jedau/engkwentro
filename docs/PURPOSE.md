The useful thing in this repo is a way to run a secret on a public chain without hiring someone to hold the secret.

Game of the Generals is the test. The rules are Pasola’s, from 1970. What this tree adds is the enforcement: hidden inputs stay hidden during play, the result is still checkable, and no operator is allowed to see both sides.

## The pattern

Six pieces, in the order the match contract actually runs them.

1. Each hidden value is committed up front as `sha256(value || salt)`. The chain stores the hash, not the value.
2. Anything the rules must watch continuously stays public. In this game that is the board: every move, because repetition, immobilisation, and a Flag reaching home cannot be detected from fights alone (`FINDINGS.md` F1).
3. The private step is a pure function of the hidden pair. `arbiter.rs` maps two ranks to `AttackerWins`, `DefenderWins`, or `BothEliminated`. It does not read the board, storage, or the chain.
4. Both parties learn that output through a small private computation (here, 1-of-15 oblivious transfer) and report it. The contract stores the agreed result. It does not learn the ranks to do so.
5. When play ends, each side opens its commitments. The contract checks the hashes, the legal multiset (`COMPOSITION`), and replays every recorded result. A lie about your own input forfeits, whoever won the public board.
6. Silence is not a veto. A missing report is a forfeit priced above anything an honest win can gain (`FORFEIT_PENALTY` 55, above `K` of 48). A mutual failure is not a cheaper exit (`VOID_PENALTY` is also 55). No decrypt key has to stay online for `settle` or a timeout. Any account can call them.

That is a deferred audit of a committed input, not a live proof. A hostile client can feed the private step a value that does not match its hash. The slash lands at the opening. `ALTERNATIVES.md` calls this Alice’s Five-star and accepts it for v0.1.0. Protocols that cannot tolerate a liar enjoying the round and paying afterward need the private input bound to the hash before the result counts. That is a later proof, not this cut.

## Where else it fits

The fit is narrow and real: the secret is fixed before play, later actions can be public, and the outcome of two secrets is a pure function. The same six steps drop onto other protocols. The Salpakan board does not.

**A second hidden-information board.** Stratego is the same game with different ranks. Battleship is simpler: each cell is a commitment, a shot is a public coordinate, hit or miss is a pure function of that cell, and the fleet opens at the end. An illegal fleet is a forfeit on open, which is the composition check with ships instead of Spies.

**A two-party sealed bid.** Both sides commit `sha256(amount || salt)`. Who won is a comparison. They report the winner; the amounts stay closed until the opening, which checks the hashes and recomputes the comparison. A procurement round with two finalists is the same function. A room full of bidders is not, unless the comparison is reduced to pairs or replaced with a proof. This pattern covers two committed numbers, not a silent n-way auction.

**A hand that was dealt once.** If the private material is a fixed set, committed at the start, and every later action is public, the showdown is an opening plus a replay. A committed lineup, a committed response to a brief, a committed set of cards from a known composition. A shoe that deals a new hidden card mid-hand does not fit. That card was not in the original commitment, so the audit has nothing to open.

**An escrow that does not hire a witness.** Two parties commit the terms. The events of the job that both are willing to sign go on-chain. They report delivered or not. Agreement releases the stake. Disagreement opens the commitments and runs a pure check against the log. During the job, neither side, and no platform key, is entitled to read the other’s unopened material. The check still happens after, so this suits work where a wrong interim call can be reversed by the forfeit. It does not suit a payment that must be correct at the moment it moves.

**A two-party sealed choice.** A vote, a jury ballot, a simultaneous pick in a negotiation. Commit the choice, tally with a pure function, open to prove the tally. The withholding rule is the part that transfers: a missing ballot is a priced abstention. It cannot freeze the count, which is the failure `FINDINGS.md` F3 is about.

**A fog-of-war map whose units have static stats.** Positions of hidden units are commitments. Movement that the rules must see is public. An encounter resolves through the same pure table and the same dual report. Discovery is the opening of one unit, or of all of them at the end. This is the cheap version of that genre: deferred audit, no server holding the map, no circuit. It is a poor fit for units whose hidden stats change every turn, because each change needs a fresh commitment the later replay can open.

## What stays valuable if nobody queues

The match contract on testnet is the proof the six steps run. A player base for Salpakan is a separate question, and `ECONOMICS.md` is where the gas and the rake live. The pattern does not depend on that audience. A sealed bid, a Battleship, or a two-party escrow can use the commit, the pure function, the dual report, and the priced silence without ever fielding a Spy.

Publish those four mechanics as the work. If the only story is “a Salpakan app,” the pattern disappears behind the board, and the next person rebuilding a trusted server for a hidden-information game will not find it.

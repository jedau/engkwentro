# Changelog

All notable changes to Engkwentro are recorded here. Versioning follows
the crate `workspace.package.version`.

## [0.1.0] — 2026-11-01

Initial implementation. This is the first cut that compiles and is meant
to be treated as the v0.1.0 baseline in every document.

### Added

- Three-crate NEAR workspace (`engkwentro`, `engkwentro-registry`,
  `engkwentro-vault`), `near-sdk` pinned at **5.30.0**.
- Match contract **v0.1.0 full surface**: setup, `apply_moves` (one move),
  dual-player `resolve_challenge` / `confirm_arrival`, draw / resign /
  timeout, `submit_setup` / `settle` / `claim_payout`. No platform
  decrypt key.
- First player is the SHA-256 bit in `docs/RULES.md` §13.
- Option 2 resolution: per-piece `sha256(rank || salt)`, 1-of-15 OT
  off-chain, dual player reports, on-chain flip + fight-log replay.
  No Merkle module. See `docs/ALTERNATIVES.md`.
- Arbiter + 225-case `MATRIX` moved into the match crate unchanged.
- Integer Elo (`K=48`, `ADV=50`, floor 25, forfeit/void 55) with baked
  `EXPECTED_SECOND` table, six invariant tests, and `apply_result`.
- Vault accounting: 250 NEAR Pro floor, `min(50, staked*15/250)` daily
  cap, 7-day unstake, simulated 5% APY, pool-driven free draws.
- Flutter client (`client/`): local pass-and-play plus two-phone testnet.
  Same `MATRIX` as the contract.
- Local keyed mailbox (`scripts/mailbox_local.mjs`) for OT blobs and
  display-only clock notes.
- Deploy / seed / gas scripts. Local pipeline test plays one full match.
- NEP-297 events, standard `engkwentro` version `1.0.0`.

### Fixed (2026-11-13)

- WalletConnect pairing showed a raw URI text dump instead of a
  scannable QR. Flutter now overlays a native `qr_flutter` code when
  SignClient emits the URI; `connect.html` also renders a canvas QR.

### Added (2026-11-13)

- Opt-in match stakes (Package S): Create dialog NEAR text box (default
  0) with winner/rake sublabel; `accept_match` is payable and requires
  a matching deposit; client attaches yocto on create/join, shows the
  pot, and `claim_payout` after settle.

### Public-repo cleanup (2026-11-13)

- Removed unused Cloudflare worker tree, offline CLI, agent pickup
  prompts, seed scripts, and archive `FOUNDATION_NOTES.md`.
- Docs describe only the live path: player-submitted play, local mailbox,
  `get_sync` / `think_ns`. Subsidised free-tier product notes moved out of
  present-tense docs into findings / roadmap where needed.
- `scripts/deploy.sh` redeploys the match account **without** `init` by
  default (`INIT_MATCH=1` for a new empty account).
- Dropped unused `MatchError::NotWorker` and stub `get_arbiter_pk`.
- Clarified docs: no cranker service; “crank” means a permissionless call.
  `WaitingForArbiter` is dual-player report wait. No `items` crate.

### Turn and clock authority (2026-11-12)

Replaces the earlier clock fixes. Model, measurements and known limits are
in `docs/CLOCKS.md`.

- Contract: `get_sync` view returns play state, stored banks,
  `turn_started_at`, chain time, block height, seats, setup flags and
  occupancy from one block.
- Contract: `apply_moves` takes optional `think_ns`. The mover is charged
  `clamp(think_ns, elapsed - 5 s, elapsed)`; the next turn starts at the
  block. `claim_timeout` requires `elapsed >= remaining + 5 s`. Stored
  layout unchanged. Redeployed without `init`
  (tx `61GL7rHsRbVSmfvACzQqNjb2SZqCo1CAoyS3ynn3uMVN`).
- Client: one `get_sync` per refresh; rows from an older block are dropped;
  seat taken from the row, with a hard error for a stranger.
- Client: `MatchDriver` is the only writer. One serialized loop shared with
  user actions; every request has a deadline and a retry.
- Client: a tap creates a pending move on the same frame. Until the chain
  shows it the overlay stays up, the mover's clock is frozen and the status
  is never "Your turn". `Battle!` stays up through the whole fight.
- Client: own clock timed locally from when the turn appears; opponent's
  clock drawn from estimated chain time, held by a display-only mailbox tap
  note (`session.tapNotes`, on by default).
- Fixed: a quiet step onto the far rank was treated as a fight on the
  mover's phone and never confirmed.
- Fixed: a second fight on the same two squares reused the first fight's
  mailbox slot and never resolved. Slots now include both nonces.
- Fixed: a failed upload of the defender's keys was never retried, leaving
  the attacker waiting.
- Fixed: `confirm_arrival` and `confirm_roster` were re-sent on every poll.
- Tests: offline two-phone simulation on virtual time
  (`client/test/two_phone_sim_test.dart`) with normal and rough network
  profiles, plus contract tests for the charge window and the flag window.

### Fixed

- `accept_match` reports `AlreadyAccepted` before the creator `SelfMatch`
  check, so a repeated accept returns the correct error. Restores the
  `open_match_binds_the_joiner` unit-test baseline.
- The join dialog now owns its `TextEditingController` in a stateful
  widget and disposes it after the route is removed. This fixes the
  “used after being disposed” exception and the cascading
  `_dependents.isEmpty` red screen on create/join.

### Client assets (2026-11-10)

- Added `flutter_svg` `^2.3.2` for the vector piece art.
- Source SVGs for 15 ranks + `hidden` in light/dark live under
  `client/assets/images/pieces/` (declared in `pubspec.yaml`; board uses
  `PieceArt`).

### Client branding (2026-11-05)

- Brand assets now live in `client/assets/images/` and are declared in
  `client/pubspec.yaml`.
- Material 3 palette follows the logo: navy `#1B2335`, gold `#C3973E`,
  cream `#F8ECBD`, sand `#D6B88F`, tan `#BE9873`. The home wordmark and
  both board renderers use the palette.
- Launcher icons generated from `engkwentro-app-icon.png` for Android,
  iOS, and web. Android uses an adaptive icon with a navy background and
  a transparent shield foreground. Web manifest, splash backgrounds, and
  system bars use the brand navy.
- Home wordmark scales with the viewport and the home content scrolls on
  short screens.

### Client playability (2026-11-11)

- Board is a 180° relative view: own home on the **bottom**, files mirrored
  for Bob so his columns 1–3 are Alice’s 7–9. Setup tray under the board.
- Progress overlay only for NEAR / fight work — not on a quiet opponent turn.
  Status line is emphasized (`titleLarge`).
- Piece SVGs (`light`/`dark`) on the board and setup tray.

### Client setup phase (2026-11-08)

- Match entry now opens an interactive **Setting the pieces** phase.
  Players place all 21 pieces in their own three home rows, with rank
  tray, tap-to-place, lift-to-move, auto-fill, clear, and a guarded
  commit. The committed local army stays visible until
  `confirm_roster` fills on-chain occupancy.

### Testnet deploy (2026-11-08)

- Redeployed the current match wasm to `play.engkwentro.testnet` without
  `init`, preserving existing match state. Code hash
  `8U2G6ajQpnouH2Ao2od9dQcxsTJFi9QSdNpeqmKMjkXQ`.
- `get_join_key`, `accept_match_by_key`, and `get_opened` now resolve on
  the live testnet contract.

### Testnet (2026-11-01 — 2026-11-02)

- Match contract live at `play.engkwentro.testnet`. Players
  `player1.engkwentro.testnet` / `player2.engkwentro.testnet`.
- Two-phone match **6** finished on devices (flag capture,
  `AwaitingFlip`). Quiet `apply_moves` burned **0.000230 NEAR**
  (2.52 TGas). `resolve_challenge` burned **0.000228 NEAR** (2.50 TGas).
  See `docs/GAS_BASELINE.md`.
- Local-only audit log (`client/lib/audit.dart`): each successful call
  prints `{tx_hash, method, match_id, tokens_burnt}`. Not written on
  chain (cheaper than extra event bytes).
- Create / join live on a lobby screen, not on the board. Grid numbers
  hidden. Board is a width-first 9×8 of square cells (`snugBoardSize`).
- Client notes in `docs/CLIENT.md`. Dartdoc on every method in
  `client/lib/`.
- Home is **Create match** / **Join match** only. No local pass-and-play.
  Players share a 12-character join key (`XXXX-XXXX-XXXX`); sequential
  `match_id` stays the on-chain audit id.
- Match poll is **1 s** (item 2 option A). No optimistic occupancy.
- Two-phone flip: after `Ended` each side `submit_setup`, then `settle`.
  `get_opened` paints both armies. Sequential item 3.
- Hackathon README rewritten for judges: Option 2 thesis, measured gas,
  do-X→see-Y, Nearblocks path, submission fields.
- Create match is a home modal; only after `create_match` does the
  match screen open (waiting on the join key). Open challenge — no
  named opponent. First mover remains the SHA-256 bit at confirm.
- Join accept runs in the modal path; the old full-screen lobby form
  is gone.
- Home **Log in**: NEAR wallet via `near_wallet_connect`, “new to NEAR”
  → MyNearWallet testnet create, NEAR Auth docs link, plus Demo Alice/Bob
  mailbox for two-phone runs. Deep link scheme `engkwentro://`.

### Client auth (2026-11-12)

- Connect sheet redesign: **Create play account** (in-app keygen +
  `helper.testnet.near.org` faucet + `flutter_secure_storage`,
  `AuthSource.local`) is the frictionless new-user path.
- Logo-first wallet chooser (`WalletRegistry` / `WalletOnboardingSheet`)
  with **WalletConnect first**, then Intear, Meteor, Bitte, HERE, HOT,
  Nightly, Sender, NEAR Mobile, MyNearWallet. Logos under
  `assets/images/wallets/`.
- WalletConnect pairing via WebView SignClient
  (`assets/wc/connect.html`, `--dart-define=REOWN_PROJECT_ID=…`). WC
  alone does not grant a local signing key; Create / Join stay gated on
  `AuthController.isLoggedIn`.
- Deep-link wallets still use `near_wallet_connect`. Demo Alice/Bob
  mailbox path unchanged. Docs: `docs/CLIENT.md`, `client/README.md`.

### Not required to version up

- Replay VOD of finished games.
- Multi-move batching above one.
- Alice’s Five-star live bind (F9). Vault /
  registry deploy.

v0.1.0 is the playable MVP. Do not bump the crate version until a stranger
can finish a match.

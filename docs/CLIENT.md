# CLIENT — v0.1.0 Flutter

The Dart app in `client/` is a signer **and** a submitter. The player
account is the NEAR predecessor. NEP-413 signatures on `SignedMove` are
empty when the caller is that player.

**Look.** Arcade chrome from Style B (`pixel_button.dart`): Press Start 2P
for titles / CTAs, VT323 for body copy, notched cream/navy blocks, sharp
dialogs and clocks — see `theme.dart`.

Dartdoc lives on every method in `client/lib/*.dart`. Generated
`arbiter.g.dart` is the `MATRIX` copy; regenerate with
`scripts/gen_arbiter_dart.sh`.

## Branding

Source assets are `client/assets/images/engkwentro-logo.svg` (wordmark)
and `engkwentro-app-icon.png` (launcher icon). A rendered
`engkwentro-logo.png` is beside them for Flutter `Image.asset`. The
`assets/images/` directory is declared in `client/pubspec.yaml`.

Palette: navy `#1B2335` (surface), gold `#C3973E` (primary/selection),
cream `#F8ECBD` (wordmark/Alice), sand `#D6B88F`, tan `#BE9873` (Bob),
brown `#B68C6A` (outlines). The single theme is `engkwentroTheme()` in
`client/lib/theme.dart`.

Launcher icons are generated from the app icon into Android
`mipmap-*`, iOS `AppIcon.appiconset`, and `web/icons` + `favicon.png`.
Android also ships an adaptive icon
(`mipmap-anydpi-v26/ic_launcher.xml`) with the navy background and a
transparent shield foreground so launchers do not shrink the legacy
square. Android and iOS splash backgrounds use the brand navy; the web
manifest background is navy and its theme color is gold.

The home wordmark takes the full 420 dp content width, capped by 26% of
the available height (120–240 dp). Home content is scrollable so short
screens do not overflow.

## Surfaces

| Route | What it is |
|---|---|
| Home | **Connect Wallet**, then Create / Join when a play-ready session exists. Always two devices |
| Connect | In-app **Create play account**, logo-first wallet list (WalletConnect first), or mailbox Demo Alice/Bob |
| Create | Confirm modal (clock + NEAR stake text box, default 0) → open `create_match` → match screen waits on key |
| Join | Key modal → `accept_match_by_key` → match screen (no lobby form) |
| Match | Set the pieces → commit → confirm after opponent joins. Flip after `Ended` |

Create and join finish on-chain **before** the match screen opens.
Create is an open challenge (no named opponent). First mover is the
SHA-256 bit at **`accept_match`**, not the creator; `confirm_roster`
reuses that side. Shareable id is a 12-character join key (alphabet
without `0 O I 1`), grouped `XXXX-XXXX-XXXX`. Sequential `match_id`
stays on the `AUDIT` line. Grid numbers are hidden. Cells are square;
`snugBoardSize` takes the width first.

## Setting the pieces

After the opponent joins, the match screen enters setup instead of
auto-committing. The tray shows the fixed 21-piece composition; tap a
rank, then a gold-outlined square in your three home rows. Tapping a
placed piece lifts it back into the tray. `Auto-fill` applies the
default layout, `Clear` empties the home rows, and `Commit army` is
enabled only when all 21 pieces are placed. Salts are generated at
commit. Until `confirm_roster` fills on-chain occupancy, the client
keeps painting the committed local army.

### Auth / Connect Wallet

Create and Join stay hidden until `AuthController.isLoggedIn` — a session
with a **local signing key** (`AuthSession.canSignLocally`). Match moves
still use `NearClient` with that key; there is no per-move wallet popup.

Wallet callbacks use the `engkwentro://` scheme. The Connect sheet
(`WalletOnboardingSheet` in `client/lib/wallet_chooser.dart`) offers:

1. **Create play account** — in-app Ed25519 (`KeyPairEd25519.generate`) +
   `POST https://helper.testnet.near.org/account` → credentials in
   `flutter_secure_storage` (`AuthSource.local`). Optional name
   (`alice` → `alice.testnet`); blank yields `player-<rand>.testnet`.
   After create, the sheet **stays open** with the account id + private
   key (`ed25519:…`) so the user can copy/import into a wallet; Continue
   closes the sheet. Home also offers **Export private key** for local
   sessions. Restored on `AuthController.init`. Play-ready immediately.
2. **Logo-first wallet list** (`WalletRegistry`) with **WalletConnect
   first**, then Intear, Meteor, Bitte, HERE, HOT (mainnet-only, dimmed),
   Nightly, Sender, NEAR Mobile, MyNearWallet. Logos live under
   `client/assets/images/wallets/`.
3. **WalletConnect** — WebView SignClient (`assets/wc/connect.html` +
   `wallet_connect_bridge.dart`) against Reown Cloud. When SignClient
   emits the pairing URI, Flutter overlays a native scannable QR
   (`qr_flutter`); Copy link / Open wallet stay as secondary actions.
   Copy `client/dart_defines.json.example` → `client/dart_defines.json`,
   paste a free Project ID from https://cloud.reown.com, then
   `flutter run --dart-define-from-file=dart_defines.json` (full restart).
   `scripts/run_two_phones.sh` forwards that file or `REOWN_PROJECT_ID`
   from `.env`. Reown’s Dart AppKit is not used (dependency conflict with
   `near_dart` / `share_plus`). A WC session alone sets
   `AuthSource.walletConnect` with an empty private key — create a play
   account to submit moves.
4. **Package deep-link wallets** (Intear / Bitte / HERE / MyNearWallet /
   HOT) via `near_wallet_connect` → `NearWalletController.connect`.
   Prefer wallets that return a function-call key for `signer()`.
   Bitte/HERE may connect without a local key; the UI then asks for a
   play account.
5. **Demo Alice/Bob** — mailbox `/dev/cred` for two-phone simulators
   (`AuthSource.demo`).

| `AuthSource` | Local key? | Typical use |
|---|---|---|
| `local` | yes | Create play account |
| `wallet` | yes (when FC key returned) | Intear / MyNearWallet deep link |
| `walletConnect` | no | WC identity only |
| `demo` | yes | Mailbox Alice/Bob |

MyNearWallet sunsets 31 Oct 2026; its testnet connect is unreliable.

Relevant modules: `auth.dart`, `local_account.dart`, `wallet_registry.dart`,
`wallet_chooser.dart`, `wallet_connect_bridge.dart`.

The join dialog owns its `TextEditingController` in `_JoinKeyDialog` and
disposes it from the dialog State. Do not move disposal back into the
caller: the dismissal animation still builds the TextField.

## Piece art

Source SVGs are in `client/assets/images/pieces/light/` and
`client/assets/images/pieces/dark/`: 15 ranks plus `hidden.svg`, all with
`viewBox="0 0 48 48"`. Declared under `flutter.assets` in `pubspec.yaml`.
`PieceArt` (`lib/pieces.dart`) paints them on the board and setup tray
via `flutter_svg`.

- `light` maps to the **first mover**, set on-chain at `accept_match` and
  returned as `get_match` field 5 (`"A"`/`"B"`). Both phones paint stable
  light/dark through setup; colours must not swap at `confirm_roster`.
  `PlaySnap.toMove` alternates every turn, so it is not the light/dark key.
- Enemy mid-game squares use `hidden.svg` (fog), not rank glyphs.

## Testnet accounts

| Role | Account |
|---|---|
| Match contract | `play.engkwentro.testnet` |
| Alice | `player1.engkwentro.testnet` |
| Bob | `player2.engkwentro.testnet` |

RPC order: FastNEAR (`rpc.testnet.fastnear.com`) first, official
`rpc.testnet.near.org` last. A 429 rotates the endpoint and backs off.
`broadcast_tx_commit` TIMEOUT polls `tx` by hash.

Keys are not `--dart-define` on the two-phone script. The local mailbox
serves `GET /dev/cred?role=A|B`.

## Occupancy and fog

`get_board_for` returns 72 ints: `0` empty, `1..=21` Alice, `22..=42`
Bob. Mid-game the client paints a rank only when the occupancy is mine.
Enemy squares are a disc. After `Ended`, `get_opened` fills both armies
and the discs become labels. Salts live in phone memory until then.

## Fights (1-of-15 OT) and arrivals

Keyed mailbox blobs, not long-poll:

1. Defender publishes 15 X25519 public keys (`recv-{from}-{to}`), keeps
   the SK for their real rank, random bytes for the other 14.
2. Attacker ChaCha20-Poly1305 seals the MATRIX row (`send-{from}-{to}`).
3. Defender opens one cell, posts `AttackerWins|0` (or `|1` if Flag)
   (`open-{from}-{to}`).
4. Both call `resolve_challenge`. The contract applies only if the two
   reports match.

**Home-row step.** Both call `confirm_arrival(is_flag)` with the real
boolean for that piece. The UI must **not** show Arrival / Breakthrough
chrome; occupancy alone is public. Only a `FlagBreakthrough` end flips
the Flag and declares the win.

Cache one offer, one seal, and one report per slot. Regenerating keys
on every poll produces `SecretBoxAuthenticationError`.

A hostile attacker can seal a fake row (Alice’s Five-star). After
`Ended`, each phone `submit_setup` with its 21 salts. `settle` is
permissionless. `get_opened` paints both armies. A fake OT row fails
the fight-log replay (delayed audit).

## Sync and clocks

One writer: `MatchDriver` (`lib/net_driver.dart`). It owns a serialized
loop shared with user actions. Each step calls **one** `get_sync` view
(turn, stored banks, seats, occupancy, block height). Stale rows are
dropped. A tap creates a `PendingMove` immediately; the overlay stays up
until the chain shows the move.

Clocks, think-time charging (`think_ns`), turn-seen / tap notes, and
overlay rules: [`CLOCKS.md`](CLOCKS.md). Ended match UI shows
`You win!` / `You lost!` and the cause beneath.

The board is always oriented so **your** home ranks are at the bottom;
the setup tray is under the board.

## Audit

After every successful `call`, `AuditLog` prints

```
AUDIT {"tx_hash","method","account","match_id","tokens_burnt","tgas"}
```

Local only. Cheaper than extra on-chain event bytes. The contract cannot
know the tx hash.

Nearblocks: Overview has no args. Open `/txns/{hash}/execution`, first
receipt, Actions, Hide N bytes — that JSON is the FunctionCall input.
Result is the return value. Logs are the gas meter.

## Two-phone run

```bash
# Host: mailbox
node scripts/mailbox_local.mjs

# Then
scripts/run_two_phones.sh
```

Android emulator reaches the host mailbox at `10.0.2.2:8787`. iOS
simulator uses `127.0.0.1:8787`.

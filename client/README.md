# Engkwentro client

Flutter/Dart. v0.1.0. Same `MATRIX` as `contracts/engkwentro/src/arbiter.rs`.

The player account is the NEAR predecessor: the app signs and submits.
See [`docs/CLIENT.md`](../docs/CLIENT.md) and [`docs/CLOCKS.md`](../docs/CLOCKS.md)
for lobby, OT, mailbox, sync, and audit. Every method in `lib/` has dartdoc.

## Run

```bash
flutter pub get
flutter run -d chrome          # home / web smoke
# two-phone testnet: scripts/run_two_phones.sh from the repo root

# WalletConnect (optional): get a free Project ID at https://cloud.reown.com
cp dart_defines.json.example dart_defines.json
# edit dart_defines.json → paste REOWN_PROJECT_ID
flutter run --dart-define-from-file=dart_defines.json
```

`--dart-define` keys are optional. Without `REOWN_PROJECT_ID`, **Create play
account**, deep-link wallets, and Demo Alice/Bob still work. The
WalletConnect tile needs a Reown Cloud project id compiled in (hot reload
is not enough — full restart). `dart_defines.json` is gitignored. The local
mailbox can serve `/dev/cred`. Default match contract is
`play.engkwentro.testnet`.

**Connect Wallet:** new users tap **Create play account** (in-app key +
testnet faucet, stored in secure storage). Existing wallets use the
logo-first list (WalletConnect first). Create / Join require a local
signing key — see [`docs/CLIENT.md`](../docs/CLIENT.md) Auth section.

## Layout

| File | Job |
|---|---|
| `lib/main.dart` | Home, create/join dialogs, local engine widgets |
| `lib/auth.dart` | Session, wallet controller, create/restore local account |
| `lib/local_account.dart` | Keygen + helper.testnet faucet + secure storage |
| `lib/wallet_chooser.dart` | Connect sheet UI (create + logo list + demo) |
| `lib/wallet_registry.dart` | Curated NEAR wallets (WC first) |
| `lib/wallet_connect_bridge.dart` | WebView SignClient + native QR for `near:testnet` |
| `lib/pixel_button.dart` | Style-B pixel CTAs |
| `lib/net_page.dart` | Match screen, setup tray, clock faces |
| `lib/net_play.dart` | Session: create / join / setup / move / OT / clocks |
| `lib/net_driver.dart` | Serialized sync loop + user actions |
| `lib/near.dart` | JSON-RPC, timeouts, retry, 429 rotate |
| `lib/ot.dart` | 1-of-15 X25519 + ChaCha20-Poly1305 |
| `lib/mailbox.dart` | Keyed PUT/GET |
| `lib/commit.dart` | `sha256(rank \|\| salt)` |
| `lib/game.dart` | Local rules engine |
| `lib/board_layout.dart` | Snug 9×8 of square cells |
| `lib/audit.dart` | Local tx log |
| `lib/theme.dart` | Brand palette + Material 3 theme |
| `lib/arbiter.g.dart` | Generated `MATRIX` — do not edit |
| `assets/images/` | Logo, app icon source, and piece SVGs |
| `assets/images/wallets/` | Wallet / WalletConnect logos for the chooser |
| `assets/wc/connect.html` | WC SignClient page loaded by the WebView bridge |
| `assets/images/pieces/light/`, `dark/` | 15 ranks + `hidden`, 48-unit SVG viewBox (`PieceArt`) |

## Tests

```bash
flutter test
```

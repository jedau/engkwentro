# Getting Started

**This is the install and run guide** for Engkwentro v0.1.0.  
Toolchain pins: [`TOOLCHAIN.md`](TOOLCHAIN.md) (`near-sdk` 5.30.0).

Mac / Apple Silicon. Testnet only. Every step is verifiable — if one doesn't verify,
stop rather than continuing.

**Short path (already have Flutter + funded demo accounts):**

```bash
node scripts/mailbox_local.mjs          # terminal 1 — OT mailbox :8787
scripts/run_two_phones.sh               # or two flutter run sessions
```

Then: Connect Wallet → Create play account or Demo Alice/Bob → Create / Join.  
Full toolchain and deploy steps are below.

## 0. Prerequisites

- [ ] macOS on arm64, `brew --prefix` is `/opt/homebrew`
- [ ] Xcode command line tools
- [ ] Android Studio with SDK Command-line Tools (optional, for emulator)
- [ ] Docker Desktop (optional; only for sandbox workspace tests)

## 1. Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
rustup target add wasm32-unknown-unknown
rustc --version && cargo --version
```

Do **not** `brew install rust` alongside rustup.

## 2. Contract tooling

```bash
cargo binstall cargo-near near-cli-rs
cargo near --version && near --version
```

## 3. Node and Flutter

```bash
# Node 20+ for the local mailbox
node --version
flutter doctor && flutter config --enable-web
```

`flutter doctor` should be green enough to run iOS simulator and/or Android.

## 4. Accounts (live play)

Funded and in use:

`play.engkwentro.testnet` · `player1.engkwentro.testnet` ·
`player2.engkwentro.testnet`

Redeploy the match wasm **without** `init` so Borsh layout and open
matches stay intact:

```bash
cd contracts/engkwentro
cargo near deploy build-non-reproducible-wasm play.engkwentro.testnet \
  without-init-call network-config testnet sign-with-keychain send
```

Or: `scripts/deploy.sh` (match defaults to without-init; set `INIT_MATCH=1`
only for a brand-new empty account). Registry and vault are optional for
the demo.

**Only the match account is live for the demo** (`play.engkwentro.testnet`).
Registry and vault compile in-tree; when deployed they must use **distinct**
accounts. The registry stores the match contract address at init and reads
only from it.

## 5. Workspace layout

```
contracts/          Cargo workspace (match, registry, vault)
client/             Flutter app + two-phone simulation tests
scripts/            mailbox, two-phone runner, deploy, gas, arbiter codegen
docs/               this guide, rules, clocks, architecture, findings
```

## 6. OT mailbox (local)

Fights and display-only clock notes need a keyed blob store.

```bash
node scripts/mailbox_local.mjs
# listens on :8787; GET /dev/cred?role=A|B can serve demo player keys
```

Point both phones at it:

```bash
--dart-define=MATCH_CONTRACT=play.engkwentro.testnet \
--dart-define=MAILBOX_URL=http://<lan-ip>:8787
```

## 7. Secrets

- `.env` and `client/dart_defines.json` are **gitignored**. Copy from
  `.env.example` / `client/dart_defines.json.example`.
- Player private keys for Demo Alice/Bob live in the mailbox process or
  `~/.near-credentials` — never in the repo.
- Do not commit Reown project ids, faucet keys, or NEAR private keys.

## 8. Two-phone verification

- [ ] `cargo test -p engkwentro` — 40 passed
- [ ] `cd client && flutter test` — 59 passed
- [ ] `play.engkwentro.testnet` holds the current match wasm
- [ ] `get_sync`, `get_join_key`, `accept_match_by_key` resolve
- [ ] `player1` / `player2` funded (~3 NEAR is enough for many matches)
- [ ] mailbox on `:8787`
- [ ] `scripts/run_two_phones.sh` or two `flutter run` sessions

## 9. Client auth (optional WalletConnect)

New users can **Create play account** inside the app (testnet faucet).
For WalletConnect pairing:

1. Create a free project at [cloud.reown.com](https://cloud.reown.com).
2. `cp client/dart_defines.json.example client/dart_defines.json`
3. Paste the Project ID into `REOWN_PROJECT_ID`.
4. Full restart with `--dart-define-from-file=dart_defines.json`.

Without that id, create-account, deep-link wallets, and Demo Alice/Bob
still work. Details: [`CLIENT.md`](CLIENT.md).

## Known gotchas

- **`cargo near deploy`** needs
  `build-non-reproducible-wasm`. Live match account: **`without-init-call`**.
- **Official RPC 429:** the client rotates to FastNEAR. Do not point both
  phones at `rpc.testnet.near.org` alone.
- **Mailbox `EADDRINUSE`:** another `:8787` is already up.
- **Hot restart after contract/client sync changes:** do a full stop/run.
- **WalletConnect without `REOWN_PROJECT_ID`:** use Create play account.
- **WC connected but Create/Join missing:** WC does not yield a local
  signing key — create a play account on the device.

# Contributing

Read this before opening a pull request. Install and run steps are in [docs/SETUP.md](docs/SETUP.md). Format and lint commands are in [STYLEGUIDE.md](STYLEGUIDE.md).

## Branch

Create a branch from `main`. Name it `<number>-<short-name>`, the name GitHub fills in on the issue.

[`.github/workflows/link-issue.yml`](.github/workflows/link-issue.yml) runs when a pull request in this repository is opened. If the branch starts with `<number>-` and that number is an issue, it appends `Closes #<number>` unless the body already has a closing keyword for that issue. Merging into `main` then closes the issue. A branch that does not start with `<number>-` is left alone. The workflow does not run again on later edits, and it does not run for a fork.

Do not commit on `main` or `master`. A fresh clone does not run the hooks until you point Git at them:

```bash
bash scripts/install-hooks.sh
```

That sets `core.hooksPath` to `.githooks`. It does not need Node, Flutter, or Cargo. After that, `.githooks/pre-commit` refuses `git commit` on `main` or `master`. A detached HEAD is not those branches, so the hook allows the commit.

## What to run

There is no `scripts/check.sh`. Before a pull request, run the checks that are in the repo.

Format and lint by hand. [STYLEGUIDE.md](STYLEGUIDE.md) says no editor setting or workflow runs them.

```bash
# from contracts/
cargo fmt
cargo clippy

# from client/
dart format .
flutter analyze
```

Tests from [docs/SETUP.md](docs/SETUP.md):

```bash
cargo test -p engkwentro
cd client && flutter test
```

Commit subject, locally:

```bash
bash scripts/check-commit-message.sh -m "type: subject"
```

[`.github/workflows/commit-messages.yml`](.github/workflows/commit-messages.yml) checks every commit subject and the pull request title. `--no-verify` skips the local hook and still fails that workflow. Format and lint are not in that workflow.

## Commit messages

The rule is [issue #1](https://github.com/jedau/engkwentro/issues/1), as `scripts/check-commit-message.sh` checks it now. Scope is optional. Only the subject is checked. A body after a blank line is fine.

```
type: subject
type(scope): subject
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`.

```
ci: check commit subjects
ci(hooks): check commit subjects
fix(contracts): reject an illegal move
```

Pull request titles use the same form. A squash merge writes the title as the commit on `main`, and CI checks the title.

`.githooks/commit-msg` runs the same script after the hooks are installed.

## Pull request

- Tests for the change: `cargo test -p engkwentro` and `cd client && flutter test`.
- Docs if behavior changed.
- [`.github/CODEOWNERS`](.github/CODEOWNERS) requests `@jedau` on every pull request.

Do not commit secrets. `.gitignore` already excludes `.env`, `.env.local`, `client/dart_defines.json`, `neardev/`, `.near-credentials/`, and `credentials.json`. Copy from `.env.example` and `client/dart_defines.json.example`. Player private keys stay in the mailbox process or `~/.near-credentials`. Do not commit Reown project ids, faucet keys, NEAR private keys, or account seeds. [docs/SETUP.md](docs/SETUP.md) §7 is the list.

## Generated file

Do not hand-edit `client/lib/arbiter.g.dart`. It is generated from `MATRIX` in `contracts/engkwentro/src/arbiter.rs`. When that constant changes, regenerate the Dart copy with `scripts/gen_arbiter_dart.sh`. Do not regenerate it for any other change. [README.md](README.md) treats that matrix as a shared constant, not something to rewrite.

## Closed designs

[docs/ALTERNATIVES.md](docs/ALTERNATIVES.md) says "Do not reopen without a dated note":

- Alice's Five-star live bind in v0.1.0
- Merkle "just for commitments"
- Putting the SK back "for kickoff only"
- A mid-game reveal to settle a 2PC dispute
- One NEAR key with resolution privilege

Do not add a Merkle composition check, a mid-game reveal, or a platform decrypt key.

## Live match

v0.1.0's live match is `play.engkwentro.testnet`. Registry and vault are in the tree and are not the live demo. [README.md](README.md) lists only the match contract as deployed.

`scripts/deploy.sh` deploys all three. The match account defaults to `play.engkwentro.testnet` and redeploys **without** `init`, so live match state and Borsh layout stay intact. Pass `INIT_MATCH=1` only for a brand-new empty account. Registry and vault always init, and they need their own accounts (`engkwentro-registry.testnet`, `engkwentro-vault.testnet`). Do not init the live match account to "refresh" it.

`cargo near deploy` needs `build-non-reproducible-wasm`. The live match account uses `without-init-call`.

## Where the rules live

- [STYLEGUIDE.md](STYLEGUIDE.md) — format and lint, run by hand
- [docs/SETUP.md](docs/SETUP.md) — install, accounts, secrets, deploy, gotchas
- [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md) — version pins
- [docs/RULES.md](docs/RULES.md) — the game
- [docs/FINDINGS.md](docs/FINDINGS.md) — dead ends
- [docs/ALTERNATIVES.md](docs/ALTERNATIVES.md) — dismissed designs
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the three contracts fit
- [docs/TRUST.md](docs/TRUST.md) — who can do what
- [docs/CLIENT.md](docs/CLIENT.md) — client auth and WalletConnect
- [docs/CLOCKS.md](docs/CLOCKS.md) — think time
- [README.md](README.md) — what is live, and the limitations of this cut

## Discussions

- [Announcements](https://github.com/jedau/engkwentro/discussions/categories/announcements)
- [General](https://github.com/jedau/engkwentro/discussions/categories/general)
- [Ideas](https://github.com/jedau/engkwentro/discussions/categories/ideas)
- [Bug reports](https://github.com/jedau/engkwentro/discussions/categories/bug-reports)
- [Polls](https://github.com/jedau/engkwentro/discussions/categories/polls)
- [Support](https://github.com/jedau/engkwentro/discussions/categories/support)

Questions go to Support. This repository has no Q&A category.

## What changed

<!-- What a reviewer needs to know. -->

The title must be `type: subject` or `type(scope): subject`. `[FIX]` and `[FEAT]` are issue titles. CI rejects them on a pull request.

## Checks

The same commands are in [CONTRIBUTING.md](https://github.com/jedau/engkwentro/blob/main/CONTRIBUTING.md).

- [ ] `cargo fmt`, `cargo clippy --target wasm32-unknown-unknown --workspace`, and `cargo clippy --all-targets --workspace` from `contracts/`
- [ ] `dart format .` and `flutter analyze` from `client/`
- [ ] `cargo test --workspace` from `contracts/`
- [ ] `flutter test` from `client/`
- [ ] `scripts/check-commit-message.sh` accepts the title and every commit subject. CI runs `scripts/check-commit-range.sh`

## Docs

Check one.

- [ ] Docs were updated
- [ ] Behavior did not change, so docs were not updated

## Checklist

- [ ] This does not revive a Merkle composition check, a mid-game reveal, or a platform decrypt key
- [ ] No private key, seed, salt, or other secret was added

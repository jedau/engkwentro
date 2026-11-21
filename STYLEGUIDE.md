# Style guide

One set of format and lint commands. The editor and CI run these, so a save and a pull request cannot disagree.

## Rust

Run these from `contracts/`. Edition 2021, rust-version 1.93, as in `contracts/Cargo.toml`.

```bash
cargo fmt
cargo clippy
```

## Dart

Run these from `client/`. Lints come from `client/analysis_options.yaml` and `package:flutter_lints`.

```bash
dart format .
flutter analyze
```

## Generated files

Do not hand-edit `client/lib/arbiter.g.dart`. It mirrors `contracts/engkwentro/src/arbiter.rs`. Regenerate it with `scripts/gen_arbiter_dart.sh`.

## Closed designs

[docs/ALTERNATIVES.md](docs/ALTERNATIVES.md) says "Do not reopen without a dated note". Do not add a Merkle composition check, a mid-game reveal, or a platform decrypt key.

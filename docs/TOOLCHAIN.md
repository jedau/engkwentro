# Toolchain — v0.1.0

| Pin | Value |
|---|---|
| rustc channel | 1.99.1 (`contracts/rust-toolchain.toml`) |
| MSRV | 1.93 (`workspace.package.rust-version`) |
| near-sdk | **5.30.0** (do not float `5`) |
| target | `wasm32-unknown-unknown` |
| crate version | 0.1.0 |
| Flutter | 3.47.7 (the version `.github/workflows/check.yml` installs) |
| Dart | 3.13.5 (the Dart bundled with that Flutter) |

`cargo test` and `cargo build --target wasm32-unknown-unknown` run from
`contracts/`. Deploy, when asked, is
`cargo near deploy build-non-reproducible-wasm` from the crate directory.

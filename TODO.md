# TODO — Engkwentro NEAR Hackathon submission

**Deadline:** 2026-11-14T23:59:00Z  
**Tracks:** `games`, `open`  
**Last reviewed:** 2026-11-12

## 1. Public repository

- [ ] Initialize git and publish the repository. (Owner: user.)
- [x] Confirm `.env` and `client/dart_defines.json` are **not** committed
      (both gitignored). Prefer a fresh first commit so no secret ever
      enters history.
- [ ] Make the repository public before submitting.
- [ ] Keep it public through judging (2026-11-18), ideally through
      2026-11-25.
- [ ] Record the repository URL for `projectUrl`.
- [ ] Enable GitHub Pages: Settings → Pages → Deploy from branch →
      `/docs` (landing at `docs/index.html`).

## 2. License

- [x] Root `LICENSE` (MIT). (2026-11-08.)

## 3. Live testnet contract

- [x] Match wasm on `play.engkwentro.testnet` without `init`.
      Latest deploy tx `61GL7rHsRbVSmfvACzQqNjb2SZqCo1CAoyS3ynn3uMVN`
      (code hash `7N4htVUuHTA2p9fDxVh4b1jMroHT5gQUXwUguPusRkaq`).
- [x] `get_sync`, join keys, think-time charging live.
- [x] Two-phone play verified after the turn/clock rewrite (create →
      join → setup → moves → fights → Flag breakthrough).
- [ ] Optional: record a clean 60 s clip for the X demo.

## 4. Demo

- [ ] Record the 60-second two-phone clip: create → join by key → move or
      fight → visible ended state.
- [ ] Publish a public X post that says the project was built at NEAR
      HACKATHON, tags `@NEARProtocol` and `#NEARHackathon`, and attaches
      the video.
- [ ] Save the X post URL for `demoUrl`.

## 5. Human submission inputs

Do not guess these.

- [ ] Project name, lead name, email, team size.
- [ ] Mainnet NEAR payout account (not the testnet play account).
- [ ] Problem/product/NEAR-role description (20–2000 characters).
- [ ] Consent; confirm this repository has not already been submitted.

## 6. Submit once

- [ ] Build the JSON payload; do not send `website`.
- [ ] Generate `requestId` once; wait for explicit confirmation before
      `POST https://nearhackathon.com/api/applications`.

## Verification

- [x] `cargo test -p engkwentro`: 40 passed.
- [x] `flutter test`: 59 passed (includes two-phone simulation).
- [x] Obsolete worker/CLI/agent docs removed; docs describe the live path.
- [x] Secrets: `.env` + `client/dart_defines.json` gitignored; no real keys in tree.

## 7. Post-demo (not blocking submit)

See [`docs/ROADMAP.md`](docs/ROADMAP.md): stake-pot UI is live (NEAR
amount text box, default 0); vault Pro and public polish, mainnet
conversion.

# ROADMAP — next 48 hours + post-submit

**Deadline:** 2026-11-14T23:59:00Z (~2 days from 2026-11-12).  
**Tracks:** `games` (+ keep `open` as backup fit).  
**Source of truth for rules:** [HACKATHON.md](https://nearhackathon.com/HACKATHON.md), Games prompt [`09-games.md`](https://github.com/nearai/near-hackathon-prompt-examples/blob/main/tracks/09-games.md).

---

## How Games is judged (what we’re missing)

| Track wish | What Engkwentro has today | Gap |
|---|---|---|
| **Game loop first** | Two-phone create → setup → move → fight/flag end verified after clock rewrite | Flip/settle on video checklist still open |
| **Economy is gameplay** | Match stake pot UI + accept deposit + claim payout on the live path | Vault Pro / Elo registry still **not** deployed on play |
| **Bonus: players don’t notice the chain** | In-app play account + local signing | Still feel “tx / submit / desync”; economy not visible as *play* |
| Hints: NEP-245, Intents, agent NPCs | Not started | **Do not** chase in 48h unless loop + stake pot are done |

Other Games entries that “feel NEAR” usually make **money or inventory move on-chain as part of the loop** (pots, shops, agent wallets). A pure rules engine with `stake: 0` reads as “Flutter board + NEAR as transport,” not an economy.

We already designed the right story in `docs/ECONOMICS.md` / vault — we just never **shipped it into the demo path**.

---

## Principle for the next 48 hours

1. **Playable demo beats polish.** One clean create→join→fight→end→flip video wins more than another UI rewrite. Clocks are good enough for demo (`docs/CLOCKS.md`).  
2. **NEAR must appear in the loop as value**, not only as a database.  
3. **Cut order (from BRIEF):** never cut client, settlement, demo, README. Cut: NFT cosmetics, Intents, bot personality, NEP-245 market.

---

## Phase A — Stabilize the loop (Day 0 → Day 1 morning)

**Goal:** One full two-phone testnet match that judges can believe.

| Priority | Item | Done when |
|---|---|---|
| P0 | Finish smoke: move → fight/OT → end → flip/settle | Checklist in `TODO.md` §3 green |
| P0 | Turn line correct (only one “Your turn”) | Seat always from `get_match` (already patched); re-verify on new match |
| P0 | Clocks “good enough” for demo | Done 2026-11-12 (`docs/CLOCKS.md`): `get_sync`, think-time charging, turn-seen hold. Two-phone play verified. |
| P1 | Public git repo + README “NEAR role” paragraph | URL ready for `projectUrl` |
| P1 | 60 s X demo script rehearsed | Create → join key → one fight or flag → ended |

**If clocks still waste hours:** ship demo with clocks hidden or static; document in README as known limitation. Do **not** burn Day 2 on another sync rewrite.

---

## Phase B — NEAR economy in the loop (Day 1 afternoon → Day 2)

**Goal:** Judges see NEAR as the prize and access layer, not a bolt-on.

### Recommended stack (fastest, already in repo)

#### B1. Stake pots (match contract — **ship first**)

`create_match` already takes `stake` and settlement already pays winners / returns stakes.

- Client: Create flow asks **stake in NEAR** (e.g. 0 / 0.1 / 1 testnet NEAR).  
- Show **pot** on match screen (`2 × stake`).  
- On end: visible **claim / settle / payout** (permissionless `settle`).  
- Demo narration: “NEAR is the prize pot and the referee.”

This is pay-*for*-stakes, not a soft-currency NFT grind. Optional zero-stake free matches keep F2P.

#### B2. Vault Pro (vault contract — **ship second if time**)

`engkwentro-vault` already has stake / unstake / daily allowance.

- Deploy vault to a testnet account (without breaking play).  
- Connect sheet: **Stake for Pro** → badge → “Pro matches / day”.  
- Demo: stake → create staked match → play → unstake queued.

This is the Premium story you discussed — **stake NEAR for access**, not “buy NFT skin.”

#### B3. Registry Elo (stretch)

Wire `apply_result` after settle so ratings move on-chain. One line in the ended UI: “Rating pending / updated.”

### What **not** to do in 48h

| Idea | Why cut |
|---|---|
| Full NEP-245 item market | Whole new game genre; Games *hint*, not requirement |
| Premium NFTs / NEP-171 badges | Looks token-first; track says game loop > token |
| NEAR Intents cross-chain shop | No time; no loop dependency |
| Agent merchant NPCs | Cool stretch post-submit |
| Pure pay-to-play gate with no free path | Conflicts with “don’t notice the chain” + F2P design |

### If you want one “item” signal without a market

Optional **half-day**: a single NEP-171 (or simple account flag) **“Pro Pass”** minted when vault stake ≥ 250 NEAR — but only *after* B1+B2. Otherwise skip.

---

## Phase C — Submit (Day 2 evening, before 23:59 UTC)

From `TODO.md` / HACKATHON.md — non-negotiable:

1. Public repository (`projectUrl`).  
2. X post with video, `@NEARProtocol` `#NEARHackathon` (`demoUrl`).  
3. `idea` field: problem + product + **how NEAR fits** (stake pot + on-chain referee + Pro vault).  
4. Tracks: `["games","open"]` (and `nfts` only if you actually shipped a pass NFT).  
5. Mainnet payout account (human).  
6. One `POST` — no second submit of the same repo.

---

## Pitch angle (for README + `idea` + X)

**Today (honest):** Engkwentro is Game of the Generals where **NEAR is the arbiter** — setups, moves, fights, and outcomes settle on-chain without a trusted host.

**With Phase B:** NEAR is also the **economy** — players lock NEAR into match pots; winners claim on-chain; optional Pro stake unlocks denser play. No off-chain soft currency ledger.

**Track fit sentence:** “The economy *is* the match: NEAR stake is the prize, the contract is the referee, and Elo/Pro live on-chain — the board is just how you earn it.”

Bonus “don’t notice the chain”: create-play-account + one-tap create/join; stake amount is the only money UX in the happy path.

---

## Post-submit roadmap (not for the deadline)

Ordered by leverage, not fantasy:

1. Stake-pot UI + payout on camera (Games track).  
2. Mainnet vault delegation + real yield sweep (`ECONOMICS.md`).  
3. Bot opponent with its own NEAR account (NPC-with-wallet → Games hint).  
4. NEP-245 cosmetics / board skins as optional market.  
5. Optional third-party submit path if free-tier gas subsidy is revisited.  
6. Intents for depositing stake from other chains.

---

## Suggested calendar

| Window | Focus |
|---|---|
| Now → deadline | Public repo, 60 s X demo, submit once |
| If time left | Stake pot UI on camera; vault Pro only if stable |

---

## Decision for you (pick one economy package)

**Package S (recommended):** Stake pot UI + settle/payout in demo.  
**Package S+:** S + deploy vault Pro stake badge.  
**Package N (avoid):** NFT / NEP-245 market before S.

Default assumption going forward: **Package S**, then **S+** only if the loop is demo-ready.

//! Local play-through of the Option 2 match surface. No network.

use crate::setup::{first_is_creator, piece_commitment};
use crate::state::SignedMove;
use crate::{setup, state, Contract, MatchError, Rank, COMPOSITION};
use near_sdk::json_types::U128;
use near_sdk::test_utils::VMContextBuilder;
use near_sdk::{testing_env, AccountId, NearToken};

fn acc(name: &str) -> AccountId {
    name.parse().unwrap()
}

fn ctx(pred: &str, deposit: u128, ts: u64, seed: [u8; 32]) {
    let mut b = VMContextBuilder::new();
    b.current_account_id(acc("engkwentro.testnet"));
    b.predecessor_account_id(acc(pred));
    b.signer_account_id(acc(pred));
    b.account_balance(NearToken::from_near(10_000));
    b.attached_deposit(NearToken::from_yoctonear(deposit));
    b.block_timestamp(ts);
    b.random_seed(seed);
    testing_env!(b.build());
}

#[allow(clippy::type_complexity)]
fn roster(side_a: bool) -> (Vec<(u8, u8, Vec<u8>)>, Vec<(Rank, u8, u8, [u8; 32])>) {
    let ranks = {
        let mut v = Vec::new();
        for (r, n) in COMPOSITION {
            for _ in 0..n {
                v.push(r);
            }
        }
        v
    };
    let ranks_range = if side_a { 0..=2 } else { 5..=7 };
    let mut commits = Vec::new();
    let mut opens = Vec::new();
    let mut i = 0usize;
    for board_rank in ranks_range {
        let files = if (side_a && board_rank == 2) || (!side_a && board_rank == 5) {
            0..3
        } else {
            0..9
        };
        for file in files {
            let salt = [i as u8 + if side_a { 1 } else { 40 }; 32];
            let rank = ranks[i];
            commits.push((
                file,
                board_rank,
                piece_commitment(rank as u8, &salt).to_vec(),
            ));
            opens.push((rank, file, board_rank, salt));
            i += 1;
        }
    }
    assert_eq!(commits.len(), 21);
    (commits, opens)
}

fn mv(id: u64, from: u8, to: u8, nonce: u64) -> SignedMove {
    SignedMove {
        match_id: id,
        from,
        to,
        nonce,
        public_key: vec![],
        signature: vec![],
    }
}

#[test]
fn one_full_match_resign_and_settle() {
    let seed = [0u8; 32];
    ctx("alice.near", 0, 1, seed);
    let mut c = Contract::init().unwrap();

    ctx("alice.near", 0, 2, seed);
    let (id, join_key) = c
        .create_match(
            Some(acc("bob.near")),
            U128(0),
            state::RulesetId::Standard,
            5,
        )
        .unwrap();
    assert_eq!(join_key.len(), crate::join::KEY_LEN);
    assert_eq!(c.get_match_id_by_key(join_key.clone()), Some(id));
    assert_eq!(c.get_join_key(id).as_deref(), Some(join_key.as_str()));

    ctx("bob.near", 0, 3, seed);
    assert_eq!(c.accept_match_by_key(join_key).unwrap(), id);

    let (ca, oa) = roster(true);
    let (cb, ob) = roster(false);
    ctx("alice.near", 0, 4, seed);
    c.commit_setup(id, ca).unwrap();
    ctx("bob.near", 0, 5, seed);
    c.commit_setup(id, cb).unwrap();

    ctx("alice.near", 0, 6, seed);
    c.confirm_roster(id).unwrap();
    assert_eq!(c.get_match_state(id).as_deref(), Some("Committed"));

    let creator_first = first_is_creator(&seed, id, b"alice.near", b"bob.near");
    let (mover, from, to) = if creator_first {
        ("alice.near", 17u8, 26u8)
    } else {
        ("bob.near", 62u8, 53u8)
    };
    ctx(mover, 0, 10_000_000, seed);
    c.apply_moves(id, vec![mv(id, from, to, 0)], None).unwrap();
    assert_eq!(c.get_match_state(id).as_deref(), Some("InProgress"));

    ctx(mover, 0, 20_000_000, seed);
    c.resign(id).unwrap();
    assert_eq!(c.get_match_state(id).as_deref(), Some("Ended"));
    let outcome = c.get_outcome(id).expect("outcome");
    assert_eq!(outcome.0, "Win");
    assert!(outcome.1 == "A" || outcome.1 == "B");
    assert_eq!(outcome.2, "Resignation");

    ctx("alice.near", 0, 30_000_000, seed);
    c.submit_setup(id, oa).unwrap();
    ctx("bob.near", 0, 31_000_000, seed);
    c.submit_setup(id, ob).unwrap();
    let opened = c.get_opened(id).expect("opened");
    assert!(opened[1] <= 14, "Alice piece 1 should be public after flip");
    assert!(opened[22] <= 14, "Bob piece 1 should be public after flip");
    ctx("outsider.near", 0, 40_000_000, seed);
    c.settle(id).unwrap();
    assert_eq!(c.get_settlement(id).as_deref(), Some("Settled"));
    c.claim_payout(id).unwrap();
    assert!(c.get_ladder_input(id).is_some());
}

const S: u64 = 1_000_000_000;

/// Plays up to `Committed` with a 5-minute clock; roster confirmed at `t0`.
/// Returns `(contract, match id, first mover account, its first move)`.
fn kicked_off(seed: [u8; 32], t0: u64) -> (Contract, u64, &'static str, (u8, u8)) {
    ctx("alice.near", 0, 1, seed);
    let mut c = Contract::init().unwrap();
    ctx("alice.near", 0, 2, seed);
    let (id, key) = c
        .create_match(
            Some(acc("bob.near")),
            U128(0),
            state::RulesetId::Standard,
            5,
        )
        .unwrap();
    ctx("bob.near", 0, 3, seed);
    c.accept_match_by_key(key).unwrap();
    let (ca, _) = roster(true);
    let (cb, _) = roster(false);
    ctx("alice.near", 0, 4, seed);
    c.commit_setup(id, ca).unwrap();
    ctx("bob.near", 0, 5, seed);
    c.commit_setup(id, cb).unwrap();
    ctx("alice.near", 0, t0, seed);
    c.confirm_roster(id).unwrap();
    let creator_first = first_is_creator(&seed, id, b"alice.near", b"bob.near");
    let (mover, mv) = if creator_first {
        ("alice.near", (17u8, 26u8))
    } else {
        ("bob.near", (62u8, 53u8))
    };
    (c, id, mover, mv)
}

#[test]
fn get_sync_is_one_consistent_row() {
    let seed = [3u8; 32];
    let t0 = 1_000 * S;
    let (c, id, mover, _) = kicked_off(seed, t0);
    let first = if mover == "alice.near" { "A" } else { "B" };

    // 7 s into the first turn, read at a known height.
    let mut b = VMContextBuilder::new();
    b.current_account_id(acc("engkwentro.testnet"));
    b.predecessor_account_id(acc("carol.near"));
    b.block_timestamp(t0 + 7 * S);
    b.block_height(4242);
    b.random_seed(seed);
    testing_env!(b.build());

    let (play, clocks, seats, occupancy) = c.get_sync(id).expect("sync");
    assert_eq!(play, c.get_play(id).unwrap());
    assert_eq!(play.0, "Committed");
    assert_eq!(play.1, first);

    let (bank_a, bank_b, started, now, paused, height) = clocks;
    assert_eq!(started, t0);
    assert_eq!(now, t0 + 7 * S);
    assert!(!paused);
    assert_eq!(height, 4242);
    // Banks are as stored at the turn start: nothing is subtracted for the
    // 7 s already played, so the row is the same all turn long.
    assert_eq!(bank_a, 300 * S);
    assert_eq!(bank_b, 300 * S);

    assert_eq!(seats.0.as_str(), "alice.near");
    assert_eq!(seats.1.as_str(), "bob.near");
    assert!(seats.2);
    assert_eq!(seats.3, first);
    assert!(seats.4 && seats.5, "both setups are committed");
    assert_eq!(occupancy, c.get_board_for(id).unwrap());
    assert_eq!(occupancy.iter().filter(|o| **o != 0).count(), 42);

    assert!(c.get_sync(id + 99).is_none());
}

#[test]
fn get_sync_reports_which_setups_are_in() {
    let seed = [7u8; 32];
    ctx("alice.near", 0, 1, seed);
    let mut c = Contract::init().unwrap();
    ctx("alice.near", 0, 2, seed);
    let (id, key) = c
        .create_match(
            Some(acc("bob.near")),
            U128(0),
            state::RulesetId::Standard,
            5,
        )
        .unwrap();
    ctx("bob.near", 0, 3, seed);
    c.accept_match_by_key(key).unwrap();
    let (_, _, seats, _) = c.get_sync(id).unwrap();
    assert!(!seats.4 && !seats.5);

    let (cb, _) = roster(false);
    ctx("bob.near", 0, 4, seed);
    c.commit_setup(id, cb).unwrap();
    let (play, clocks, seats, _) = c.get_sync(id).unwrap();
    assert_eq!(play.0, "Created");
    assert!(!seats.4 && seats.5);
    // No turn yet: the clock has not started.
    assert_eq!(clocks.2, 0);
}

#[test]
fn mover_is_charged_for_thinking_not_for_the_network() {
    let seed = [4u8; 32];
    let t0 = 1_000 * S;
    let (mut c, id, mover, (from, to)) = kicked_off(seed, t0);
    let mover_is_a = mover == "alice.near";

    // The turn lasted 10 s block to block; the phone showed it for 8 s.
    let landed = t0 + 10 * S;
    ctx(mover, 0, landed, seed);
    c.apply_moves(
        id,
        vec![mv(id, from, to, 0)],
        Some(near_sdk::json_types::U64(8 * S)),
    )
    .unwrap();

    ctx("carol.near", 0, landed, seed);
    let (_, (bank_a, bank_b, started, _, paused, _), _, _) = c.get_sync(id).unwrap();
    let (mover_bank, other_bank) = if mover_is_a {
        (bank_a, bank_b)
    } else {
        (bank_b, bank_a)
    };
    // Mover paid for 8 s of thinking, not the 2 s of network.
    assert_eq!(mover_bank, 300 * S - 8 * S);
    // The next turn starts at the block, so nobody pays for those 2 s.
    assert_eq!(started, landed);
    assert_eq!(other_bank, 300 * S);
    assert!(!paused);

    // 3 s later the banks are untouched; the live view drains the opponent.
    ctx("carol.near", 0, landed + 3 * S, seed);
    let (_, (bank_a, bank_b, started, now, ..), _, _) = c.get_sync(id).unwrap();
    assert_eq!(
        (bank_a.min(bank_b), bank_a.max(bank_b)),
        (300 * S - 8 * S, 300 * S)
    );
    assert_eq!(now - started, 3 * S);
    let (live_a, live_b, ..) = c.get_clocks(id).unwrap();
    let (mover_live, other_live) = if mover_is_a {
        (live_a, live_b)
    } else {
        (live_b, live_a)
    };
    assert_eq!(mover_live, 300 * S - 8 * S);
    assert_eq!(other_live, 300 * S - 3 * S);
}

#[test]
fn a_think_claim_cannot_buy_more_than_the_cap() {
    let seed = [5u8; 32];
    let t0 = 1_000 * S;
    let (mut c, id, mover, (from, to)) = kicked_off(seed, t0);
    let mover_is_a = mover == "alice.near";

    // Thought for 60 s, then claims not to have thought at all.
    let landed = t0 + 60 * S;
    ctx(mover, 0, landed, seed);
    c.apply_moves(
        id,
        vec![mv(id, from, to, 0)],
        Some(near_sdk::json_types::U64(0)),
    )
    .unwrap();

    ctx("carol.near", 0, landed, seed);
    let (_, (bank_a, bank_b, ..), _, _) = c.get_sync(id).unwrap();
    let mover_bank = if mover_is_a { bank_a } else { bank_b };
    assert_eq!(mover_bank, 300 * S - 60 * S + crate::play::LAG_CAP_NS);
}

#[test]
fn flag_is_claimable_only_after_the_lag_window() {
    let seed = [6u8; 32];
    let t0 = 1_000 * S;
    let (mut c, id, mover, (from, to)) = kicked_off(seed, t0);
    let cap = crate::play::LAG_CAP_NS;

    // Bank is 300 s. One second past zero the flag is not claimable yet.
    ctx("carol.near", 0, t0 + 301 * S, seed);
    assert_eq!(c.claim_timeout(id).unwrap_err(), MatchError::WrongState);

    // A move committed with 1 s left still counts while it is in flight.
    let mut c2 = {
        let (c2, id2, mover2, (f2, t2)) = kicked_off(seed, t0);
        assert_eq!((id2, mover2, f2, t2), (id, mover, from, to));
        c2
    };
    ctx(mover, 0, t0 + 302 * S, seed);
    c2.apply_moves(
        id,
        vec![mv(id, from, to, 0)],
        Some(near_sdk::json_types::U64(299 * S)),
    )
    .unwrap();
    assert_eq!(c2.get_match_state(id).as_deref(), Some("InProgress"));

    // Without a claim the same late move is a loss on time.
    let (mut c3, ..) = kicked_off(seed, t0);
    ctx(mover, 0, t0 + 302 * S, seed);
    c3.apply_moves(id, vec![mv(id, from, to, 0)], None).unwrap();
    assert_eq!(c3.get_match_state(id).as_deref(), Some("Ended"));
    assert_eq!(c3.get_outcome(id).unwrap().2, "Timeout");

    // A claim of thinking past the bank is a loss on time too.
    let (mut c4, ..) = kicked_off(seed, t0);
    ctx(mover, 0, t0 + 302 * S, seed);
    c4.apply_moves(
        id,
        vec![mv(id, from, to, 0)],
        Some(near_sdk::json_types::U64(300 * S)),
    )
    .unwrap();
    assert_eq!(c4.get_outcome(id).unwrap().2, "Timeout");

    // Once the window has passed, anyone can drop the flag.
    ctx("carol.near", 0, t0 + 300 * S + cap, seed);
    c.claim_timeout(id).unwrap();
    assert_eq!(c.get_match_state(id).as_deref(), Some("Ended"));
    assert_eq!(c.get_outcome(id).unwrap().2, "Timeout");
}

#[test]
fn unknown_match_is_an_error() {
    ctx("alice.near", 0, 1, [1u8; 32]);
    let c = Contract::init().unwrap();
    assert_eq!(c.get_match_state(99), None);
    let mut c = c;
    assert_eq!(c.accept_match(99).unwrap_err(), MatchError::UnknownMatch);
}

#[test]
fn first_player_helper_is_used() {
    let _ = setup::PIECES_PER_SIDE;
}

#[test]
fn open_match_binds_the_joiner() {
    let seed = [2u8; 32];
    ctx("alice.near", 0, 1, seed);
    let mut c = Contract::init().unwrap();
    ctx("alice.near", 0, 2, seed);
    let (id, key) = c
        .create_match(None, U128(0), state::RulesetId::Standard, 5)
        .unwrap();
    let info = c.get_match(id).unwrap();
    assert_eq!(info.1.as_str(), crate::join::OPEN_OPPONENT);
    assert!(!info.2);
    ctx("carol.near", 0, 3, seed);
    assert_eq!(c.accept_match_by_key(key).unwrap(), id);
    let info = c.get_match(id).unwrap();
    assert_eq!(info.1.as_str(), "carol.near");
    assert!(info.2);
    assert!(info.4 == "A" || info.4 == "B", "first set at accept");
    ctx("alice.near", 0, 4, seed);
    assert_eq!(c.accept_match(id).unwrap_err(), MatchError::AlreadyAccepted);
}

#[test]
fn staked_accept_requires_matching_deposit() {
    let seed = [9u8; 32];
    let stake = 10u128.pow(24); // 1 NEAR
    ctx("alice.near", stake, 1, seed);
    let mut c = Contract::init().unwrap();

    ctx("alice.near", stake, 2, seed);
    let (id, key) = c
        .create_match(None, U128(stake), state::RulesetId::Standard, 5)
        .unwrap();
    assert_eq!(c.get_match(id).unwrap().3, stake);

    // Joiner without deposit is refused.
    ctx("bob.near", 0, 3, seed);
    assert_eq!(
        c.accept_match_by_key(key.clone()).unwrap_err(),
        MatchError::InsufficientDeposit
    );

    // Matching deposit binds the pot.
    ctx("bob.near", stake, 4, seed);
    assert_eq!(c.accept_match_by_key(key).unwrap(), id);
    assert!(c.get_match(id).unwrap().2);
}

#[test]
fn create_with_stake_refuses_short_deposit() {
    let seed = [8u8; 32];
    let stake = 10u128.pow(24);
    ctx("alice.near", 0, 1, seed);
    let mut c = Contract::init().unwrap();
    ctx("alice.near", stake / 2, 2, seed);
    assert_eq!(
        c.create_match(None, U128(stake), state::RulesetId::Standard, 5)
            .unwrap_err(),
        MatchError::InsufficientDeposit
    );
}

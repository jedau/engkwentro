#![allow(clippy::type_complexity)]
//! One scripted match, same moves, Option 2 vs modelled worker receipts.

use crate::moves::{check_legal, occupant_side};
use crate::setup::{first_is_creator, piece_commitment};
use crate::state::{Side, SignedMove};
use crate::{setup, state, Contract, Rank, COMPOSITION};
use near_sdk::json_types::U128;
use near_sdk::test_utils::VMContextBuilder;
use near_sdk::{env, testing_env, AccountId, NearToken};

const TARGET_MOVES: usize = 60;
const SEED: [u8; 32] = [0u8; 32];

fn acc(name: &str) -> AccountId {
    name.parse().unwrap()
}

fn ctx(pred: &str, ts: u64) {
    let mut b = VMContextBuilder::new();
    b.current_account_id(acc("engkwentro.testnet"));
    b.predecessor_account_id(acc(pred));
    b.signer_account_id(acc(pred));
    b.account_balance(NearToken::from_near(10_000));
    b.attached_deposit(NearToken::from_yoctonear(0));
    b.block_timestamp(ts);
    b.random_seed(SEED);
    testing_env!(b.build());
}

fn ranks() -> Vec<Rank> {
    let mut v = Vec::new();
    for (r, n) in COMPOSITION {
        for _ in 0..n {
            v.push(r);
        }
    }
    v
}

fn roster(side_a: bool) -> (Vec<(u8, u8, Vec<u8>)>, Vec<(Rank, u8, u8, [u8; 32])>) {
    let rs = ranks();
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
            let rank = rs[i];
            commits.push((
                file,
                board_rank,
                piece_commitment(rank as u8, &salt).to_vec(),
            ));
            opens.push((rank, file, board_rank, salt));
            i += 1;
        }
    }
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

fn rank_at(occ: u8) -> Rank {
    let rs = ranks();
    if (1..=21).contains(&occ) {
        rs[(occ - 1) as usize]
    } else {
        rs[(occ - 22) as usize]
    }
}

fn progress(side: Side, from: u8, to: u8) -> i16 {
    let dr = i16::from(to / 9) - i16::from(from / 9);
    match side {
        Side::A => dr,
        Side::B => -dr,
    }
}

fn pick_move(occ: &[u8], side: Side, allow_fight: bool, turn: u64) -> Option<(u8, u8, bool)> {
    let mut board = [0u8; 72];
    board.copy_from_slice(occ);
    let mut quiet = Vec::new();
    let mut fights = Vec::new();
    for from in 0..72u8 {
        if occupant_side(board[from as usize]) != Some(side) {
            continue;
        }
        let f = from % 9;
        let r = from / 9;
        for (df, dr) in [(-1i16, 0), (1, 0), (0, -1), (0, 1)] {
            let nf = i16::from(f) + df;
            let nr = i16::from(r) + dr;
            if !(0..=8).contains(&nf) || !(0..=7).contains(&nr) {
                continue;
            }
            let to = (nf + nr * 9) as u8;
            if !check_legal(&board, side, from, to) {
                continue;
            }
            let dest = board[to as usize];
            let is_fight = occupant_side(dest)
                == Some(match side {
                    Side::A => Side::B,
                    Side::B => Side::A,
                });
            if is_fight && (dest == 1 || dest == 22) {
                continue;
            }
            let score = progress(side, from, to) * 10
                + if (turn + u64::from(from)).is_multiple_of(2) {
                    i16::from(to % 9)
                } else {
                    8 - i16::from(to % 9)
                };
            if is_fight {
                fights.push((from, to, score));
            } else {
                quiet.push((from, to, score));
            }
        }
    }
    if allow_fight {
        if let Some(&(from, to, _)) = fights.iter().max_by_key(|t| t.2) {
            return Some((from, to, true));
        }
    }
    quiet
        .iter()
        .max_by_key(|t| t.2)
        .map(|&(from, to, _)| (from, to, false))
}

struct Rec {
    kind: &'static str,
    gas: u64,
}

#[test]
fn sixty_move_option2_vs_worker() {
    let _ = setup::PIECES_PER_SIDE;
    let mut ts = 1_000_000_000u64;
    ctx("alice.near", ts);
    let mut c = Contract::init().unwrap();
    let mut log: Vec<Rec> = Vec::new();

    ts += 1_000_000_000;
    ctx("alice.near", ts);
    let (id, _join_key) = c
        .create_match(
            Some(acc("bob.near")),
            U128(0),
            state::RulesetId::Standard,
            15,
        )
        .unwrap();
    log.push(Rec {
        kind: "create_match",
        gas: env::used_gas().as_gas(),
    });

    ts += 1_000_000_000;
    ctx("bob.near", ts);
    c.accept_match(id).unwrap();
    log.push(Rec {
        kind: "accept_match",
        gas: env::used_gas().as_gas(),
    });

    let (ca, oa) = roster(true);
    let (cb, ob) = roster(false);
    ts += 1_000_000_000;
    ctx("alice.near", ts);
    c.commit_setup(id, ca).unwrap();
    log.push(Rec {
        kind: "commit_setup",
        gas: env::used_gas().as_gas(),
    });
    ts += 1_000_000_000;
    ctx("bob.near", ts);
    c.commit_setup(id, cb).unwrap();
    log.push(Rec {
        kind: "commit_setup",
        gas: env::used_gas().as_gas(),
    });
    ts += 1_000_000_000;
    ctx("alice.near", ts);
    c.confirm_roster(id).unwrap();
    log.push(Rec {
        kind: "confirm_roster",
        gas: env::used_gas().as_gas(),
    });

    let creator_first = first_is_creator(&SEED, id, b"alice.near", b"bob.near");
    let mut side = if creator_first { Side::A } else { Side::B };
    let mut nonce_a = 0u64;
    let mut nonce_b = 0u64;
    let mut fights = 0usize;
    let mut arrivals = 0usize;
    let mut apply_count = 0usize;
    let mut first_report_gas = Vec::new();
    let mut apply_report_gas = Vec::new();

    while apply_count < TARGET_MOVES {
        if c.get_match_state(id).as_deref() == Some("Ended") {
            break;
        }
        let board = c.get_board_for(id).unwrap();
        let pred = if side == Side::A {
            "alice.near"
        } else {
            "bob.near"
        };
        let allow_fight = std::env::var("COST_SIM_FIGHTS")
            .map(|v| v != "0")
            .unwrap_or(true)
            && apply_count >= 12;
        let Some((from, to, is_fight)) = pick_move(&board, side, allow_fight, apply_count as u64)
        else {
            break;
        };
        let nonce = if side == Side::A { nonce_a } else { nonce_b };
        let from_occ = board[from as usize];
        let to_occ = board[to as usize];
        ts += 1_000_000_000;
        ctx(pred, ts);
        c.apply_moves(id, vec![mv(id, from, to, nonce)], None)
            .unwrap();
        log.push(Rec {
            kind: "apply_moves",
            gas: env::used_gas().as_gas(),
        });
        apply_count += 1;
        if side == Side::A {
            nonce_a += 1;
        } else {
            nonce_b += 1;
        }

        if c.get_match_state(id).as_deref() == Some("WaitingForArbiter") {
            let fight = is_fight || occupant_side(to_occ).is_some();
            if fight {
                let ex = crate::resolve(rank_at(from_occ), rank_at(to_occ));
                let flag = rank_at(to_occ) == Rank::Flag;
                ts += 1_000_000_000;
                ctx("alice.near", ts);
                c.resolve_challenge(id, ex, flag).unwrap();
                let g1 = env::used_gas().as_gas();
                first_report_gas.push(g1);
                log.push(Rec {
                    kind: "resolve_challenge",
                    gas: g1,
                });
                ts += 1_000_000_000;
                ctx("bob.near", ts);
                c.resolve_challenge(id, ex, flag).unwrap();
                let g2 = env::used_gas().as_gas();
                apply_report_gas.push(g2);
                log.push(Rec {
                    kind: "resolve_challenge",
                    gas: g2,
                });
                fights += 1;
            } else {
                ts += 1_000_000_000;
                ctx("alice.near", ts);
                c.confirm_arrival(id, false).unwrap();
                let g1 = env::used_gas().as_gas();
                first_report_gas.push(g1);
                log.push(Rec {
                    kind: "confirm_arrival",
                    gas: g1,
                });
                ts += 1_000_000_000;
                ctx("bob.near", ts);
                c.confirm_arrival(id, false).unwrap();
                let g2 = env::used_gas().as_gas();
                apply_report_gas.push(g2);
                log.push(Rec {
                    kind: "confirm_arrival",
                    gas: g2,
                });
                arrivals += 1;
            }
            if c.get_match_state(id).as_deref() == Some("Ended") {
                break;
            }
        }
        side = match side {
            Side::A => Side::B,
            Side::B => Side::A,
        };
    }

    let ended = c.get_match_state(id).as_deref() == Some("Ended");
    if !ended {
        let pred = if side == Side::A {
            "alice.near"
        } else {
            "bob.near"
        };
        ts += 1_000_000_000;
        ctx(pred, ts);
        c.resign(id).unwrap();
        log.push(Rec {
            kind: "resign",
            gas: env::used_gas().as_gas(),
        });
    }
    ts += 1_000_000_000;
    ctx("alice.near", ts);
    c.submit_setup(id, oa).unwrap();
    log.push(Rec {
        kind: "submit_setup",
        gas: env::used_gas().as_gas(),
    });
    ts += 1_000_000_000;
    ctx("bob.near", ts);
    c.submit_setup(id, ob).unwrap();
    log.push(Rec {
        kind: "submit_setup",
        gas: env::used_gas().as_gas(),
    });
    ts += 1_000_000_000;
    ctx("outsider.near", ts);
    c.settle(id).unwrap();
    log.push(Rec {
        kind: "settle",
        gas: env::used_gas().as_gas(),
    });
    ts += 1_000_000_000;
    ctx("alice.near", ts);
    c.claim_payout(id).unwrap();
    log.push(Rec {
        kind: "claim_payout",
        gas: env::used_gas().as_gas(),
    });

    let option2_receipts = log.len();
    let option2_gas: u64 = log.iter().map(|r| r.gas).sum();
    let first_sum: u64 = first_report_gas.iter().sum();
    let worker_receipts = option2_receipts - fights - arrivals + 2;
    let verify_proxy =
        apply_report_gas.iter().copied().sum::<u64>() / apply_report_gas.len().max(1) as u64;
    let worker_gas = option2_gas.saturating_sub(first_sum) + verify_proxy.saturating_mul(2);

    println!("COST_SIM_JSON");
    println!("target_moves={TARGET_MOVES}");
    println!("apply_moves={apply_count}");
    println!("fights={fights}");
    println!("arrivals={arrivals}");
    println!("ended_before_resign={ended}");
    println!("option2_receipts={option2_receipts}");
    println!("worker_receipts={worker_receipts}");
    println!("option2_gas={option2_gas}");
    println!("worker_gas_model={worker_gas}");
    println!("first_report_gas_sum={first_sum}");
    println!("apply_report_n={}", apply_report_gas.len());
    for kind in [
        "create_match",
        "accept_match",
        "commit_setup",
        "confirm_roster",
        "apply_moves",
        "resolve_challenge",
        "confirm_arrival",
        "resign",
        "submit_setup",
        "settle",
        "claim_payout",
    ] {
        let xs: Vec<u64> = log
            .iter()
            .filter(|r| r.kind == kind)
            .map(|r| r.gas)
            .collect();
        if !xs.is_empty() {
            println!("kind={kind} n={} gas={}", xs.len(), xs.iter().sum::<u64>());
        }
    }
    println!("COST_SIM_END");

    assert!(
        apply_count >= 20,
        "sim produced only {apply_count} moves; pick_move is stuck"
    );
}

//! In-match mutations. Clock, end, post-move checks.

use crate::errors::MatchError;
use crate::moves::{has_legal_move, other, position_key, repetition_count};
use crate::state::{
    DrawReason, ForfeitCause, Match, MatchState, Outcome, SettlementStatus, Side, VoidReason,
    WinReason,
};

pub const SETTLEMENT_WINDOW_NS: u64 = 5 * 60 * 1_000_000_000;
pub const RAKE_BPS: u128 = 150;

/// Most network time credited back to the mover, per move.
///
/// A mover is charged for the time the turn was visibly theirs: from their
/// phone showing the turn until they commit to a move. The phone reports
/// that duration (`think_ns`). The chain only knows how long the turn lasted
/// block to block, and the difference is network time: the turn reaching the
/// phone, and the move reaching a block. The claim is untrusted, so at most
/// this much is credited: a modified client gains `LAG_CAP_NS` per move.
pub const LAG_CAP_NS: u64 = 5 * 1_000_000_000;

/// Elapsed think time since [turn_started_at], or 0 if the turn has not begun.
///
/// No grace pad: the bank drains from the block that started the turn.
pub fn charged_elapsed(turn_started_at: u64, now: u64) -> u64 {
    if turn_started_at == 0 {
        return 0;
    }
    now.saturating_sub(turn_started_at)
}

/// Chain time the mover is charged up to, for a move landing at `now`.
///
/// Without a claim this is `now`: the whole turn, block to block. With one,
/// the charge is `think_ns` clamped into `[elapsed - LAG_CAP_NS, elapsed]`,
/// so a claim can never credit more than the cap or charge more than the
/// turn lasted. Returned as a time so [`charge_clock`] can take it as `now`.
pub fn charge_until(turn_started_at: u64, now: u64, think_ns: Option<u64>) -> u64 {
    let Some(think) = think_ns else {
        return now;
    };
    let elapsed = charged_elapsed(turn_started_at, now);
    let charged = think.clamp(elapsed.saturating_sub(LAG_CAP_NS), elapsed);
    now - (elapsed - charged)
}

pub fn charge_clock(m: &mut Match, side: Side, now: u64) -> Result<(), MatchError> {
    if m.clocks_paused {
        return Ok(());
    }
    let elapsed = charged_elapsed(m.turn_started_at, now);
    let rem = m.remaining(side);
    if elapsed >= rem {
        *m.remaining_mut(side) = 0;
        return Err(MatchError::ClockFlag);
    }
    *m.remaining_mut(side) = rem - elapsed;
    Ok(())
}

/// View-time banks with the side-to-move's elapsed already subtracted.
///
/// Clients re-anchor from this snapshot and only tick wall time since the
/// fetch — they must not also subtract `now - turn_started_at`.
pub fn live_banks(m: &Match, now: u64) -> (u64, u64) {
    let mut a = m.remaining_a;
    let mut b = m.remaining_b;
    if m.clocks_paused {
        return (a, b);
    }
    let Some(side) = m.to_move else {
        return (a, b);
    };
    let elapsed = charged_elapsed(m.turn_started_at, now);
    match side {
        Side::A => a = a.saturating_sub(elapsed),
        Side::B => b = b.saturating_sub(elapsed),
    }
    (a, b)
}

pub fn end_match(m: &mut Match, outcome: Outcome, now: u64) {
    m.state = MatchState::Ended { outcome };
    m.settlement = Some(SettlementStatus::AwaitingFlip {
        deadline: now.saturating_add(SETTLEMENT_WINDOW_NS),
    });
    m.clocks_paused = true;
    m.to_move = None;
}

pub fn finish_turn(m: &mut Match, mover: Side, now: u64) -> Result<(), MatchError> {
    let incoming = other(mover);
    if !has_legal_move(&m.occupancy, incoming) {
        let reason = if matches!(m.state, MatchState::Breakthrough { .. }) {
            WinReason::FlagBreakthrough
        } else {
            WinReason::Immobilised
        };
        end_match(
            m,
            Outcome::Win {
                winner: mover,
                reason,
            },
            now,
        );
        return Ok(());
    }
    m.to_move = Some(incoming);
    m.turn_started_at = now;
    m.clocks_paused = false;
    m.state = MatchState::InProgress;
    m.draw_offered_by = None;
    Ok(())
}

pub fn check_repetition(m: &mut Match, incoming: Side, now: u64) -> bool {
    let key = position_key(&m.occupancy, incoming);
    let count = repetition_count(&m.history, &key) + 1;
    m.history.push(key);
    if count >= 3 {
        end_match(
            m,
            Outcome::Draw {
                reason: DrawReason::Repetition,
            },
            now,
        );
        true
    } else {
        false
    }
}

pub fn timeout_loser(m: &mut Match, loser: Side, now: u64) {
    end_match(
        m,
        Outcome::Win {
            winner: other(loser),
            reason: WinReason::Timeout,
        },
        now,
    );
}

pub fn forfeit_side(m: &mut Match, by: Side, now: u64, cause: ForfeitCause) {
    end_match(
        m,
        Outcome::Win {
            winner: other(by),
            reason: WinReason::OpponentForfeited(cause),
        },
        now,
    );
    m.settlement = Some(SettlementStatus::Forfeited { by });
}

pub fn void_match(m: &mut Match, now: u64) {
    end_match(
        m,
        Outcome::Void {
            reason: VoidReason::MutualSettlementFailure,
        },
        now,
    );
    m.settlement = Some(SettlementStatus::Voided);
}

pub fn payout_amounts(stake: u128) -> (u128, u128) {
    if stake == 0 {
        return (0, 0);
    }
    let pot = stake.saturating_mul(2);
    let rake = pot.saturating_mul(RAKE_BPS) / 10_000;
    (pot.saturating_sub(rake), rake)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{Match, MatchState, RulesetId};

    fn sample() -> Match {
        Match {
            id: 1,
            creator: "alice.near".parse().unwrap(),
            opponent: "bob.near".parse().unwrap(),
            accepted: true,
            stake: 0,
            ruleset: RulesetId::Standard,
            clock_ns: 60_000_000_000,
            remaining_a: 60_000_000_000,
            remaining_b: 60_000_000_000,
            state: MatchState::InProgress,
            settlement: None,
            first: Some(Side::A),
            to_move: Some(Side::B),
            next_nonce_a: 0,
            next_nonce_b: 0,
            placements_a: None,
            placements_b: None,
            occupancy: [0; 72],
            history: Vec::new(),
            turn_started_at: 0,
            clocks_paused: false,
            draw_offered_by: None,
            claimed_a: false,
            claimed_b: false,
            verified_a: None,
            verified_b: None,
            paid: false,
            waiting_mover: None,
            pending_by: None,
            pending_exchange: None,
            pending_flag: false,
            resolution_deadline: 0,
            fight_log: Vec::new(),
            opened: [255; 43],
        }
    }

    #[test]
    fn rake_is_one_and_a_half_percent() {
        let (payout, rake) = payout_amounts(10_000);
        assert_eq!(rake, 300);
        assert_eq!(payout, 19_700);
    }

    #[test]
    fn live_banks_subtract_elapsed_from_side_to_move() {
        let mut m = sample();
        m.remaining_a = 60_000_000_000;
        m.remaining_b = 45_000_000_000;
        m.to_move = Some(Side::B);
        m.turn_started_at = 1_000;
        m.clocks_paused = false;
        let (a0, b0) = live_banks(&m, 1_000);
        assert_eq!(a0, 60_000_000_000);
        assert_eq!(b0, 45_000_000_000);
        let (a, b) = live_banks(&m, 1_000 + 5_000_000_000);
        assert_eq!(a, 60_000_000_000);
        assert_eq!(b, 40_000_000_000);
        m.clocks_paused = true;
        let (a2, b2) = live_banks(&m, 1_000 + 5_000_000_000);
        assert_eq!(a2, 60_000_000_000);
        assert_eq!(b2, 45_000_000_000);
    }

    #[test]
    fn charged_elapsed_starts_immediately() {
        let started = 1_000;
        assert_eq!(charged_elapsed(0, started + 1), 0);
        assert_eq!(charged_elapsed(started, started), 0);
        assert_eq!(
            charged_elapsed(started, started + 5_000_000_000),
            5_000_000_000
        );
    }

    #[test]
    fn charge_until_honours_a_claim_inside_the_window() {
        const S: u64 = 1_000_000_000;
        let started = 100 * S;
        let now = 110 * S;
        // No claim: charged block to block.
        assert_eq!(charge_until(started, now, None), now);
        // Thought for 8 s; the other 2 s were network.
        assert_eq!(charge_until(started, now, Some(8 * S)), 108 * S);
        // A claim below the cap is pulled up to `elapsed - LAG_CAP_NS`.
        assert_eq!(charge_until(started, now, Some(S)), now - LAG_CAP_NS);
        assert_eq!(charge_until(started, now, Some(0)), now - LAG_CAP_NS);
        // A claim longer than the turn is pulled down to the turn.
        assert_eq!(charge_until(started, now, Some(999 * S)), now);
    }

    #[test]
    fn charge_until_never_credits_more_than_the_turn() {
        const S: u64 = 1_000_000_000;
        let started = 100 * S;
        // The move lands 2 s into the turn, inside the cap: a zero claim
        // makes the whole turn free, and nothing before it.
        let now = 102 * S;
        assert_eq!(charge_until(started, now, Some(0)), started);
        // A turn that never started charges nothing either way.
        assert_eq!(charge_until(0, now, Some(5 * S)), now);
        assert_eq!(charged_elapsed(0, charge_until(0, now, Some(5 * S))), 0);
    }

    #[test]
    fn incoming_side_with_no_piece_is_immobilised() {
        let mut m = sample();
        m.occupancy[0] = 1;
        finish_turn(&mut m, Side::A, 1).unwrap();
        assert!(matches!(
            m.state,
            MatchState::Ended {
                outcome: Outcome::Win {
                    winner: Side::A,
                    reason: WinReason::Immobilised,
                },
            }
        ));
    }

    #[test]
    fn a_challenge_counts_as_a_legal_reply() {
        let mut m = sample();
        m.occupancy[0] = 1;
        m.occupancy[1] = 22;
        finish_turn(&mut m, Side::A, 1).unwrap();
        assert_eq!(m.to_move, Some(Side::B));
        assert!(matches!(m.state, MatchState::InProgress));
    }
}

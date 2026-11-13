//! Pure move pipeline. No `env`. Order is RULES.md §5.

use crate::arbiter::Exchange;
use crate::state::Side;

pub const BOARD: usize = 72;

pub fn file_of(sq: u8) -> u8 {
    sq % 9
}

pub fn rank_of(sq: u8) -> u8 {
    sq / 9
}

pub fn in_bounds(sq: u8) -> bool {
    (sq as usize) < BOARD
}

/// Orthogonal neighbour, not diagonal, distance 1.
pub fn is_legal_step(from: u8, to: u8) -> bool {
    if !in_bounds(from) || !in_bounds(to) || from == to {
        return false;
    }
    let df = i16::from(file_of(from)) - i16::from(file_of(to));
    let dr = i16::from(rank_of(from)) - i16::from(rank_of(to));
    (df.abs() == 1 && dr == 0) || (df == 0 && dr.abs() == 1)
}

pub fn occupant_side(cell: u8) -> Option<Side> {
    match cell {
        0 => None,
        1..=21 => Some(Side::A),
        22..=42 => Some(Side::B),
        _ => None,
    }
}

pub fn enemy_home_rank(side: Side) -> u8 {
    match side {
        Side::A => 7,
        Side::B => 0,
    }
}

pub fn on_enemy_home(side: Side, sq: u8) -> bool {
    in_bounds(sq) && rank_of(sq) == enemy_home_rank(side)
}

/// Legality only. Does not mutate.
pub fn check_legal(occ: &[u8; 72], side: Side, from: u8, to: u8) -> bool {
    if !is_legal_step(from, to) {
        return false;
    }
    let Some(from_side) = occupant_side(occ[from as usize]) else {
        return false;
    };
    if from_side != side {
        return false;
    }
    !matches!(occupant_side(occ[to as usize]), Some(s) if s == side)
}

pub fn has_legal_move(occ: &[u8; 72], side: Side) -> bool {
    for from in 0..72u8 {
        if occupant_side(occ[from as usize]) != Some(side) {
            continue;
        }
        let f = file_of(from);
        let r = rank_of(from);
        let candidates = [
            (f.wrapping_sub(1), r),
            (f + 1, r),
            (f, r.wrapping_sub(1)),
            (f, r + 1),
        ];
        for (nf, nr) in candidates {
            if nf > 8 || nr > 7 {
                continue;
            }
            let to = nf + nr * 9;
            if check_legal(occ, side, from, to) {
                return true;
            }
        }
    }
    false
}

pub fn apply_quiet(occ: &mut [u8; 72], from: u8, to: u8) {
    occ[to as usize] = occ[from as usize];
    occ[from as usize] = 0;
}

/// Apply an `Exchange`. Returns whether any piece was removed.
pub fn apply_exchange(occ: &mut [u8; 72], from: u8, to: u8, exchange: Exchange) -> bool {
    match exchange {
        Exchange::AttackerWins => {
            occ[to as usize] = occ[from as usize];
            occ[from as usize] = 0;
            true
        }
        Exchange::DefenderWins => {
            occ[from as usize] = 0;
            true
        }
        Exchange::BothEliminated => {
            occ[from as usize] = 0;
            occ[to as usize] = 0;
            true
        }
    }
}

pub fn position_key(occ: &[u8; 72], to_move: Side) -> [u8; 32] {
    let mut buf = Vec::with_capacity(73);
    buf.extend_from_slice(occ);
    buf.push(match to_move {
        Side::A => 0,
        Side::B => 1,
    });
    let digest = near_sdk::env::sha256(&buf);
    let mut out = [0u8; 32];
    out.copy_from_slice(&digest);
    out
}

pub fn repetition_count(history: &[[u8; 32]], key: &[u8; 32]) -> usize {
    history.iter().filter(|k| *k == key).count()
}

pub fn other(side: Side) -> Side {
    match side {
        Side::A => Side::B,
        Side::B => Side::A,
    }
}

pub fn move_message(match_id: u64, from: u8, to: u8, nonce: u64) -> Vec<u8> {
    let mut buf = b"engkwentro/move/v0.1.0".to_vec();
    buf.extend_from_slice(&match_id.to_le_bytes());
    buf.push(from);
    buf.push(to);
    buf.extend_from_slice(&nonce.to_le_bytes());
    near_sdk::env::sha256(&buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty() -> [u8; 72] {
        [0; 72]
    }

    #[test]
    fn step_is_orthogonal_only() {
        assert!(is_legal_step(0, 1));
        assert!(is_legal_step(0, 9));
        assert!(!is_legal_step(0, 10));
        assert!(!is_legal_step(0, 2));
        assert!(!is_legal_step(0, 0));
    }

    #[test]
    fn friendly_block() {
        let mut occ = empty();
        occ[0] = 1;
        occ[1] = 2;
        assert!(!check_legal(&occ, Side::A, 0, 1));
        occ[1] = 22;
        assert!(check_legal(&occ, Side::A, 0, 1));
    }

    #[test]
    fn quiet_move() {
        let mut occ = empty();
        occ[0] = 1;
        apply_quiet(&mut occ, 0, 1);
        assert_eq!(occ[0], 0);
        assert_eq!(occ[1], 1);
    }

    #[test]
    fn exchange_split_clears_both() {
        let mut occ = empty();
        occ[0] = 1;
        occ[1] = 22;
        apply_exchange(&mut occ, 0, 1, Exchange::BothEliminated);
        assert_eq!(occ[0], 0);
        assert_eq!(occ[1], 0);
    }

    #[test]
    fn lone_piece_has_a_move() {
        let mut occ = empty();
        occ[0] = 1;
        assert!(has_legal_move(&occ, Side::A));
        occ[1] = 2;
        occ[9] = 3;
        assert!(!check_legal(&occ, Side::A, 0, 1));
        occ[1] = 22;
        assert!(check_legal(&occ, Side::A, 0, 1));
    }

    #[test]
    fn enemy_homes() {
        assert!(on_enemy_home(Side::A, 63));
        assert!(on_enemy_home(Side::B, 0));
        assert!(!on_enemy_home(Side::A, 0));
    }

    #[test]
    fn a_challenge_is_a_legal_destination() {
        let mut occ = empty();
        occ[4] = 1;
        occ[3] = 22;
        occ[5] = 23;
        occ[13] = 24;
        assert!(has_legal_move(&occ, Side::A));
    }
}

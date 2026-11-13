//! Integer Elo. Authoritative algorithm in `docs/RULES.md` §11.
//! One signed transfer `t` from the second player's view. No floats.

use crate::config::{
    FIRST_MOVE_ADVANTAGE, FORFEIT_PENALTY, K_FACTOR_VOLATILITY, RATING_DIFF_CLAMP, RATING_FLOOR,
    RATING_SCALE, VOID_PENALTY,
};
use crate::expected::EXPECTED_SECOND;

pub fn div_round_half_away(n: i64, d: i64) -> i32 {
    let q = if n >= 0 {
        (n + d / 2) / d
    } else {
        -(((-n) + d / 2) / d)
    };
    q as i32
}

fn clamp_transfer(r_first: u32, r_second: u32, d_first: i32) -> (i32, i32) {
    if d_first == 0 {
        return (0, 0);
    }
    if d_first > 0 {
        let pay = (d_first as u32).min(r_second.saturating_sub(RATING_FLOOR));
        (pay as i32, -(pay as i32))
    } else {
        let pay = ((-d_first) as u32).min(r_first.saturating_sub(RATING_FLOOR));
        (-(pay as i32), pay as i32)
    }
}

/// Standard win/draw/loss. `s_second` is `RATING_SCALE`, half, or 0.
pub fn standard_delta(r_first: u32, r_second: u32, s_second: i64) -> (i32, i32) {
    let d = (r_first as i64 + FIRST_MOVE_ADVANTAGE as i64 - r_second as i64)
        .clamp(-(RATING_DIFF_CLAMP as i64), RATING_DIFF_CLAMP as i64);
    let e = EXPECTED_SECOND[(d + RATING_DIFF_CLAMP as i64) as usize] as i64;
    let raw = (K_FACTOR_VOLATILITY as i64) * (s_second - e);
    let t = div_round_half_away(raw, RATING_SCALE as i64);
    clamp_transfer(r_first, r_second, -t)
}

pub fn forfeit_delta(loser_rating: u32) -> u32 {
    FORFEIT_PENALTY.min(loser_rating.saturating_sub(RATING_FLOOR))
}

pub fn void_delta(rating: u32) -> u32 {
    VOID_PENALTY.min(rating.saturating_sub(RATING_FLOOR))
}

pub fn apply_standard(r_first: u32, r_second: u32, s_second: i64) -> (u32, u32) {
    let (df, ds) = standard_delta(r_first, r_second, s_second);
    (
        (r_first as i64 + df as i64) as u32,
        (r_second as i64 + ds as i64) as u32,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{FORFEIT_PENALTY, K_FACTOR_VOLATILITY, RATING_SCALE, VOID_PENALTY};

    #[test]
    fn forfeiture_always_costs_more_than_a_worst_case_loss() {
        const { assert!(FORFEIT_PENALTY > K_FACTOR_VOLATILITY) };
    }

    #[test]
    fn void_is_never_cheaper_than_a_solo_forfeit() {
        const { assert!(VOID_PENALTY >= FORFEIT_PENALTY) };
    }

    #[test]
    fn equal_1200_vectors() {
        let scale = RATING_SCALE as i64;
        let (f, s) = standard_delta(1200, 1200, scale);
        assert_eq!((f, s), (-27, 27));
        let (f, s) = standard_delta(1200, 1200, 0);
        assert_eq!((f, s), (21, -21));
        let (f, s) = standard_delta(1200, 1200, scale / 2);
        assert_eq!((f, s), (-3, 3));
    }

    #[test]
    fn floor_clamp_preserves_zero_sum() {
        let (df, ds) = clamp_transfer(30, 1200, -27);
        assert_eq!((df, ds), (-5, 5));
        assert_eq!(df + ds, 0);
    }

    #[test]
    fn adv_favours_second_on_a_draw() {
        let (f, s) = standard_delta(1200, 1200, RATING_SCALE as i64 / 2);
        assert!(s > 0 && f < 0);
    }

    #[test]
    fn expected_table_centre() {
        assert_eq!(EXPECTED_SECOND[800], 5000);
        assert_eq!(EXPECTED_SECOND[850], 4285);
    }
}

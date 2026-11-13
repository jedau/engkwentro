//! Pure vault math. No `env`. Integer only.

pub const YOCTO: u128 = 10u128.pow(24);
pub const MIN_STAKE_YOCTO: u128 = 250 * YOCTO;
pub const UNSTAKE_DELAY_NS: u64 = 7 * 24 * 60 * 60 * 1_000_000_000;
pub const STAKING_APY_BPS: u128 = 500;
pub const YEAR_NS: u128 = 365 * 24 * 60 * 60 * 1_000_000_000;
pub const PRO_BASE_NEAR: u128 = 250;
pub const PRO_BASE_MATCHES: u128 = 15;
pub const PRO_CAP: u32 = 50;
pub const DAY_NS: u64 = 24 * 60 * 60 * 1_000_000_000;

/// Pro daily cap. 0 if below the floor or an unstake is live.
pub fn matches_per_day(principal: u128, unstake_pending: bool) -> u32 {
    if unstake_pending || principal < MIN_STAKE_YOCTO {
        return 0;
    }
    let near = principal / YOCTO;
    let raw = (near * PRO_BASE_MATCHES) / PRO_BASE_NEAR;
    if raw > PRO_CAP as u128 {
        PRO_CAP
    } else {
        raw as u32
    }
}

/// `a * b / denom` when the result fits in `u128`.
fn mul_div(a: u128, b: u128, denom: u128) -> u128 {
    if denom == 0 {
        return 0;
    }
    let hi = a / denom;
    let lo = a % denom;
    hi.saturating_mul(b)
        .saturating_add(lo.saturating_mul(b) / denom)
}

pub fn accrue_yield(principal: u128, allowance: u128, elapsed_ns: u64) -> u128 {
    if principal == 0 || elapsed_ns == 0 {
        return allowance;
    }
    let yearly = mul_div(principal, STAKING_APY_BPS, 10_000);
    let y = mul_div(yearly, elapsed_ns as u128, YEAR_NS);
    allowance.saturating_add(y)
}

/// Healthy pool → 1/day; thin → 1/week; empty handled by the caller.
pub fn free_interval_ns(pool: u128, seeded: u128) -> u64 {
    if seeded == 0 || pool == 0 {
        return u64::MAX;
    }
    let bps = pool.saturating_mul(10_000) / seeded;
    if bps >= 5_000 {
        DAY_NS
    } else if bps >= 2_000 {
        7 * DAY_NS
    } else {
        30 * DAY_NS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pro_table() {
        assert_eq!(matches_per_day(249 * YOCTO, false), 0);
        assert_eq!(matches_per_day(250 * YOCTO, false), 15);
        assert_eq!(matches_per_day(500 * YOCTO, false), 30);
        assert_eq!(matches_per_day(750 * YOCTO, false), 45);
        assert_eq!(matches_per_day(834 * YOCTO, false), 50);
        assert_eq!(matches_per_day(10_000 * YOCTO, false), 50);
        assert_eq!(matches_per_day(500 * YOCTO, true), 0);
    }

    #[test]
    fn yield_is_five_percent_over_a_year() {
        let y = accrue_yield(250 * YOCTO, 0, YEAR_NS as u64);
        assert_eq!(y, 250 * YOCTO * 500 / 10_000);
    }

    #[test]
    fn free_rate_degrades() {
        assert_eq!(free_interval_ns(100, 100), DAY_NS);
        assert_eq!(free_interval_ns(40, 100), 7 * DAY_NS);
        assert_eq!(free_interval_ns(10, 100), 30 * DAY_NS);
        assert_eq!(free_interval_ns(0, 100), u64::MAX);
    }
}

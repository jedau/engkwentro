//! Ladder constants. Verbatim from `docs/RULES.md` §11. Compile-time by design:
//! retuning means a redeploy, which keeps the rating engine free of an admin
//! surface.

pub const K_FACTOR_VOLATILITY: u32 = 48;
pub const FIRST_MOVE_ADVANTAGE: u32 = 50;
pub const FORFEIT_PENALTY: u32 = 55;
pub const VOID_PENALTY: u32 = 55;
pub const START_RATING: u32 = 1200;
pub const RATING_FLOOR: u32 = 25;
pub const RATING_SCALE: u32 = 10_000;
pub const RATING_DIFF_CLAMP: u32 = 800;

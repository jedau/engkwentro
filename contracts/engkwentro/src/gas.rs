//! Gas metering. Wrap every mutating method from the first one implemented.

use near_sdk::borsh::{BorshDeserialize, BorshSerialize};
use near_sdk::store::LookupMap;
use near_sdk::{env, Gas};

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh", use_discriminant = true)]
#[repr(u8)]
pub enum ActionKind {
    Init = 0,
    CreateMatch = 1,
    AcceptMatch = 2,
    CommitSetup = 3,
    ConfirmRoster = 4,
    ApplyMoves = 5,
    ResolveChallenge = 6,
    ConfirmArrival = 7,
    OfferDraw = 8,
    AcceptDraw = 9,
    Resign = 10,
    ClaimTimeout = 11,
    SubmitSetup = 12,
    VerifySetup = 13,
    Settle = 14,
    ClaimPayout = 15,
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, Debug, Default)]
#[borsh(crate = "near_sdk::borsh")]
pub struct GasStat {
    pub calls: u64,
    pub last_tgas: u64,
    pub max_tgas: u64,
}

impl ActionKind {
    pub fn as_key(self) -> u8 {
        self as u8
    }
}

pub fn record(stats: &mut LookupMap<u8, GasStat>, kind: ActionKind, used: Gas) {
    let tgas = used.as_gas() / 1_000_000_000_000;
    let mut stat = stats.get(&kind.as_key()).cloned().unwrap_or_default();
    stat.calls = stat.calls.saturating_add(1);
    stat.last_tgas = tgas;
    if tgas > stat.max_tgas {
        stat.max_tgas = tgas;
    }
    stats.insert(kind.as_key(), stat);
    env::log_str(&format!(
        "gas kind={:?} tgas={} calls={}",
        kind, tgas, stat.calls
    ));
}

/// Run `f` and record `env::used_gas()` after it (NEAR SDK 5 name for burnt gas).
#[allow(dead_code)]
pub fn meter<T>(stats: &mut LookupMap<u8, GasStat>, kind: ActionKind, f: impl FnOnce() -> T) -> T {
    let before = env::used_gas();
    let out = f();
    let used = env::used_gas().saturating_sub(before);
    record(stats, kind, used);
    out
}

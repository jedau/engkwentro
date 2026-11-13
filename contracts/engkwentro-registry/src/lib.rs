//! Engkwentro registry v0.1.0. Integer Elo plus `apply_result` guards.

mod config;
mod errors;
mod expected;
mod rating;

pub use config::{
    FIRST_MOVE_ADVANTAGE, FORFEIT_PENALTY, K_FACTOR_VOLATILITY, RATING_DIFF_CLAMP, RATING_FLOOR,
    RATING_SCALE, START_RATING, VOID_PENALTY,
};
pub use errors::RegistryError;
pub use rating::{apply_standard, forfeit_delta, standard_delta, void_delta};

use near_sdk::store::LookupMap;
use near_sdk::{near, AccountId, PanicOnDefault};

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Contract {
    match_contract: AccountId,
    applied: LookupMap<u64, bool>,
    ratings: LookupMap<AccountId, u32>,
}

#[near]
impl Contract {
    /// Pre: none. Post: only `match_contract` may source results.
    #[init]
    #[handle_result]
    pub fn init(match_contract: AccountId) -> Result<Self, RegistryError> {
        Ok(Self {
            match_contract,
            applied: LookupMap::new(b"a"),
            ratings: LookupMap::new(b"r"),
        })
    }

    pub fn get_rating(&self, account: AccountId) -> u32 {
        self.ratings.get(&account).copied().unwrap_or(START_RATING)
    }

    /// Permissionless. `kind`: 0 first wins, 1 second wins, 2 draw, 3 void,
    /// 4 first forfeits, 5 second forfeits. First/second are kickoff colours.
    /// The caller must have read `get_ladder_input` from the match contract;
    /// v0.1.0 does not issue the cross-contract view (match never calls out).
    #[handle_result]
    pub fn apply_result(
        &mut self,
        match_id: u64,
        first: AccountId,
        second: AccountId,
        kind: u8,
    ) -> Result<(), RegistryError> {
        if self.applied.get(&match_id).copied().unwrap_or(false) {
            return Err(RegistryError::AlreadyApplied);
        }
        if first == second {
            return Err(RegistryError::NotTerminal);
        }
        let r1 = self.ratings.get(&first).copied().unwrap_or(START_RATING);
        let r2 = self.ratings.get(&second).copied().unwrap_or(START_RATING);
        let (n1, n2) = match kind {
            0 => apply_standard(r1, r2, 0),
            1 => apply_standard(r1, r2, RATING_SCALE as i64),
            2 => apply_standard(r1, r2, RATING_SCALE as i64 / 2),
            3 => (
                r1.saturating_sub(void_delta(r1)),
                r2.saturating_sub(void_delta(r2)),
            ),
            4 => {
                let pay = forfeit_delta(r1);
                (r1.saturating_sub(pay), r2.saturating_add(pay))
            }
            5 => {
                let pay = forfeit_delta(r2);
                (r1.saturating_add(pay), r2.saturating_sub(pay))
            }
            _ => return Err(RegistryError::NotTerminal),
        };
        self.ratings.insert(first, n1);
        self.ratings.insert(second, n2);
        self.applied.insert(match_id, true);
        Ok(())
    }
}

//! Engkwentro vault v0.1.0. Pro stake, 7-day unstake, allowance, free pool.

mod errors;
mod math;

pub use errors::VaultError;
pub use math::{
    accrue_yield, free_interval_ns, matches_per_day, DAY_NS, MIN_STAKE_YOCTO, STAKING_APY_BPS,
    UNSTAKE_DELAY_NS, YOCTO,
};

use near_sdk::borsh::{BorshDeserialize, BorshSerialize};
use near_sdk::json_types::U128;
use near_sdk::store::LookupMap;
use near_sdk::{env, near, AccountId, NearToken, PanicOnDefault, Promise};

#[derive(BorshSerialize, BorshDeserialize, Clone, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub struct Position {
    pub principal: u128,
    pub last_accrual: u64,
    pub allowance: u128,
    pub unstake_at: Option<u64>,
    pub last_free_draw: u64,
}

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Contract {
    owner: AccountId,
    positions: LookupMap<AccountId, Position>,
    free_pool: u128,
    seeded_pool: u128,
}

#[near]
impl Contract {
    /// Pre: none. Post: owner stored, maps empty.
    #[init]
    #[handle_result]
    pub fn init(owner: AccountId) -> Result<Self, VaultError> {
        Ok(Self {
            owner,
            positions: LookupMap::new(b"p"),
            free_pool: 0,
            seeded_pool: 0,
        })
    }

    pub fn min_stake(&self) -> U128 {
        U128(MIN_STAKE_YOCTO)
    }

    pub fn get_free_pool(&self) -> U128 {
        U128(self.free_pool)
    }

    pub fn get_position(&self, account: AccountId) -> Option<(U128, U128, Option<u64>, u32)> {
        self.positions.get(&account).map(|p| {
            (
                U128(p.principal),
                U128(p.allowance),
                p.unstake_at,
                matches_per_day(p.principal, p.unstake_at.is_some()),
            )
        })
    }

    pub fn is_pro(&self, account: AccountId) -> bool {
        self.positions
            .get(&account)
            .map(|p| matches_per_day(p.principal, p.unstake_at.is_some()) > 0)
            .unwrap_or(false)
    }

    pub fn matches_per_day_of(&self, account: AccountId) -> u32 {
        self.positions
            .get(&account)
            .map(|p| matches_per_day(p.principal, p.unstake_at.is_some()))
            .unwrap_or(0)
    }

    /// Owner seeds the free-match pool. Attached deposit is added.
    #[payable]
    #[handle_result]
    pub fn fund_pool(&mut self) -> Result<(), VaultError> {
        if env::predecessor_account_id() != self.owner {
            return Err(VaultError::NotOwner);
        }
        let amt = env::attached_deposit().as_yoctonear();
        self.free_pool = self.free_pool.saturating_add(amt);
        self.seeded_pool = self.seeded_pool.saturating_add(amt);
        Ok(())
    }

    /// Lock at least 250 NEAR. Adding to an existing lock is allowed.
    /// Pro ends the moment an unstake is requested; staking is refused then.
    #[payable]
    #[handle_result]
    pub fn stake(&mut self) -> Result<(), VaultError> {
        let account = env::predecessor_account_id();
        let added = env::attached_deposit().as_yoctonear();
        let now = env::block_timestamp();
        let mut pos = self.positions.get(&account).cloned().unwrap_or(Position {
            principal: 0,
            last_accrual: now,
            allowance: 0,
            unstake_at: None,
            last_free_draw: 0,
        });
        if pos.unstake_at.is_some() {
            return Err(VaultError::AlreadyProPending);
        }
        pos.allowance = accrue_yield(
            pos.principal,
            pos.allowance,
            now.saturating_sub(pos.last_accrual),
        );
        pos.last_accrual = now;
        pos.principal = pos.principal.saturating_add(added);
        if pos.principal < MIN_STAKE_YOCTO {
            return Err(VaultError::BelowMinStake);
        }
        self.positions.insert(account, pos);
        Ok(())
    }

    /// First call starts the 7-day window and drops Pro. Second call after
    /// the window returns principal. Allowance is claimed separately.
    #[handle_result]
    pub fn unstake(&mut self) -> Result<(), VaultError> {
        let account = env::predecessor_account_id();
        let now = env::block_timestamp();
        let Some(mut pos) = self.positions.get(&account).cloned() else {
            return Err(VaultError::NotStaked);
        };
        pos.allowance = accrue_yield(
            pos.principal,
            pos.allowance,
            now.saturating_sub(pos.last_accrual),
        );
        pos.last_accrual = now;
        match pos.unstake_at {
            None => {
                pos.unstake_at = Some(now.saturating_add(UNSTAKE_DELAY_NS));
                self.positions.insert(account, pos);
                Ok(())
            }
            Some(ready) if now < ready => Err(VaultError::UnstakeNotReady),
            Some(_) => {
                let principal = pos.principal;
                pos.principal = 0;
                pos.unstake_at = None;
                self.positions.insert(account.clone(), pos);
                if principal > 0 {
                    let _ = Promise::new(account).transfer(NearToken::from_yoctonear(principal));
                }
                Ok(())
            }
        }
    }

    /// Pays accrued 5% APY (testnet-simulated) to the caller.
    #[handle_result]
    pub fn claim_allowance(&mut self) -> Result<U128, VaultError> {
        let account = env::predecessor_account_id();
        let now = env::block_timestamp();
        let Some(mut pos) = self.positions.get(&account).cloned() else {
            return Err(VaultError::NotStaked);
        };
        pos.allowance = accrue_yield(
            pos.principal,
            pos.allowance,
            now.saturating_sub(pos.last_accrual),
        );
        pos.last_accrual = now;
        let pay = pos.allowance;
        if pay == 0 {
            self.positions.insert(account, pos);
            return Err(VaultError::NothingToClaim);
        }
        pos.allowance = 0;
        self.positions.insert(account, pos);
        // Testnet yield is simulated. Principal stays locked; no extra NEAR is minted.
        Ok(U128(pay))
    }

    /// Non-Pro free-match draw. Interval degrades with the pool.
    #[handle_result]
    pub fn draw_free_pool(&mut self) -> Result<(), VaultError> {
        if self.free_pool == 0 {
            return Err(VaultError::PoolEmpty);
        }
        let account = env::predecessor_account_id();
        let now = env::block_timestamp();
        let interval = free_interval_ns(self.free_pool, self.seeded_pool);
        let mut pos = self.positions.get(&account).cloned().unwrap_or(Position {
            principal: 0,
            last_accrual: now,
            allowance: 0,
            unstake_at: None,
            last_free_draw: 0,
        });
        if matches_per_day(pos.principal, pos.unstake_at.is_some()) > 0 {
            return Err(VaultError::AlreadyProPending);
        }
        if pos.last_free_draw > 0 && now.saturating_sub(pos.last_free_draw) < interval {
            return Err(VaultError::FreeRateLimited);
        }
        pos.last_free_draw = now;
        self.positions.insert(account, pos);
        Ok(())
    }
}

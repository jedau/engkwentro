use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VaultError {
    NotImplemented,
    BelowMinStake,
    NotStaked,
    UnstakePending,
    UnstakeNotReady,
    NothingToClaim,
    PoolEmpty,
    FreeRateLimited,
    NotOwner,
    AlreadyProPending,
}

impl fmt::Display for VaultError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            VaultError::NotImplemented => "not implemented in v0.1.0",
            VaultError::BelowMinStake => "stake below 250 NEAR",
            VaultError::NotStaked => "no stake",
            VaultError::UnstakePending => "unstake already requested",
            VaultError::UnstakeNotReady => "7-day unstake window has not elapsed",
            VaultError::NothingToClaim => "no accrued allowance",
            VaultError::PoolEmpty => "free pool is empty",
            VaultError::FreeRateLimited => "free-pool draw not yet available",
            VaultError::NotOwner => "only the vault owner may call this",
            VaultError::AlreadyProPending => "cannot stake while an unstake is pending",
        };
        f.write_str(s)
    }
}

impl From<VaultError> for String {
    fn from(e: VaultError) -> Self {
        e.to_string()
    }
}

impl near_sdk::FunctionError for VaultError {
    fn panic(&self) -> ! {
        near_sdk::env::panic_str(&self.to_string())
    }
}

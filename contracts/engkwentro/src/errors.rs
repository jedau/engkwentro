//! Match contract errors. One variant per failure mode.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MatchError {
    NotImplemented,
    Unauthorized,
    InvalidClockMinutes,
    UnknownMatch,
    AlreadyAccepted,
    NotAccepted,
    NotPlayer,
    SelfMatch,
    InvalidRuleset,
    SetupAlreadyCommitted,
    InvalidSetup,
    WrongState,
    SetupsIncomplete,
    InvalidNonce,
    InvalidSignature,
    NotToMove,
    IllegalMove,
    ClockFlag,
    InsufficientDeposit,
    EmptyBatch,
    AlreadyPaid,
    NotEnded,
    FlipIncomplete,
}

impl fmt::Display for MatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            MatchError::NotImplemented => "not implemented in v0.1.0",
            MatchError::Unauthorized => "unauthorized",
            MatchError::InvalidClockMinutes => "clock_minutes must be 1..=15",
            MatchError::UnknownMatch => "unknown match",
            MatchError::AlreadyAccepted => "match already accepted",
            MatchError::NotAccepted => "opponent has not accepted",
            MatchError::NotPlayer => "caller is not a player in this match",
            MatchError::SelfMatch => "cannot challenge self",
            MatchError::InvalidRuleset => "unknown ruleset",
            MatchError::SetupAlreadyCommitted => "setup already committed",
            MatchError::InvalidSetup => "invalid setup",
            MatchError::WrongState => "illegal source state",
            MatchError::SetupsIncomplete => "both setups are required",
            MatchError::InvalidNonce => "unexpected move nonce",
            MatchError::InvalidSignature => "NEP-413 signature rejected",
            MatchError::NotToMove => "not this side's turn",
            MatchError::IllegalMove => "illegal move",
            MatchError::ClockFlag => "clock expired",
            MatchError::InsufficientDeposit => "attached deposit below stake",
            MatchError::EmptyBatch => "apply_moves requires exactly one move in v0.1.0",
            MatchError::AlreadyPaid => "payout already claimed",
            MatchError::NotEnded => "match has not ended",
            MatchError::FlipIncomplete => "both sides have not been verified",
        };
        f.write_str(s)
    }
}

impl From<MatchError> for String {
    fn from(e: MatchError) -> Self {
        e.to_string()
    }
}

impl near_sdk::FunctionError for MatchError {
    fn panic(&self) -> ! {
        near_sdk::env::panic_str(&self.to_string())
    }
}

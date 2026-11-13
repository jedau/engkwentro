//! Match types. `Rank` and `COMPOSITION` are re-exported from `arbiter`.

use crate::arbiter::{self, Exchange};
use crate::setup::COMMITMENT_LEN;
use near_sdk::borsh::{BorshDeserialize, BorshSerialize};
use near_sdk::AccountId;

#[allow(unused_imports)]
pub use crate::arbiter::{Rank, COMPOSITION};

pub type MatchId = u64;

/// Wire square: `file + board_rank * 9`, range 0..=71.
pub fn square_index(file: u8, board_rank: u8) -> Option<u8> {
    if file > 8 || board_rank > 7 {
        return None;
    }
    Some(file + board_rank * 9)
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
#[cfg_attr(
    feature = "serde",
    derive(serde::Serialize, serde::Deserialize, schemars::JsonSchema)
)]
pub enum Side {
    /// Creator. Home rows 0–2.
    A,
    /// Opponent. Home rows 5–7.
    B,
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
#[cfg_attr(
    feature = "serde",
    derive(serde::Serialize, serde::Deserialize, schemars::JsonSchema)
)]
pub enum RulesetId {
    Standard,
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub enum MatchState {
    Created,
    Committed,
    InProgress,
    WaitingForArbiter { from: u8, to: u8 },
    Breakthrough { by: Side, at: u8, deadline: u64 },
    Ended { outcome: Outcome },
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub enum SettlementStatus {
    AwaitingFlip { deadline: u64 },
    Settled,
    Forfeited { by: Side },
    Voided,
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub enum Outcome {
    Win { winner: Side, reason: WinReason },
    Draw { reason: DrawReason },
    Void { reason: VoidReason },
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub enum WinReason {
    FlagCaptured,
    FlagBreakthrough,
    Resignation,
    Immobilised,
    Timeout,
    OpponentForfeited(ForfeitCause),
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub enum ForfeitCause {
    InvalidSetup,
    SettlementTimeout,
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub enum DrawReason {
    Agreement,
    Repetition,
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub enum VoidReason {
    MutualSettlementFailure,
}

#[derive(BorshSerialize, BorshDeserialize, Clone, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub struct Placement {
    pub file: u8,
    pub board_rank: u8,
    pub commitment: [u8; COMMITMENT_LEN],
}

#[derive(BorshSerialize, BorshDeserialize, Clone, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
#[cfg_attr(
    feature = "serde",
    derive(serde::Serialize, serde::Deserialize, schemars::JsonSchema)
)]
pub struct SignedMove {
    pub match_id: MatchId,
    pub from: u8,
    pub to: u8,
    pub nonce: u64,
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

/// Occupant of a square. Positions are public; ranks are not.
#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[borsh(crate = "near_sdk::borsh")]
#[allow(dead_code)]
pub struct Piece {
    pub side: Side,
    pub index: u8,
}

#[derive(BorshSerialize, BorshDeserialize, Clone, Debug)]
#[borsh(crate = "near_sdk::borsh")]
pub struct Match {
    pub id: MatchId,
    pub creator: AccountId,
    pub opponent: AccountId,
    pub accepted: bool,
    pub stake: u128,
    pub ruleset: RulesetId,
    pub clock_ns: u64,
    pub remaining_a: u64,
    pub remaining_b: u64,
    pub state: MatchState,
    pub settlement: Option<SettlementStatus>,
    pub first: Option<Side>,
    pub to_move: Option<Side>,
    pub next_nonce_a: u64,
    pub next_nonce_b: u64,
    pub placements_a: Option<Vec<Placement>>,
    pub placements_b: Option<Vec<Placement>>,
    /// 0 empty, 1..=21 side A, 22..=42 side B.
    pub occupancy: [u8; 72],
    pub history: Vec<[u8; 32]>,
    pub turn_started_at: u64,
    pub clocks_paused: bool,
    pub draw_offered_by: Option<Side>,
    pub claimed_a: bool,
    pub claimed_b: bool,
    pub verified_a: Option<bool>,
    pub verified_b: Option<bool>,
    pub paid: bool,
    pub waiting_mover: Option<Side>,
    pub pending_by: Option<Side>,
    pub pending_exchange: Option<crate::arbiter::Exchange>,
    pub pending_flag: bool,
    pub resolution_deadline: u64,
    /// `(occ_from, occ_to, exchange)` recorded before the pieces move. Replayed at flip.
    pub fight_log: Vec<(u8, u8, u8)>,
    /// Piece-index → rank. `255` means not yet opened.
    pub opened: [u8; 43],
}

impl Match {
    pub fn side_of(&self, account: &AccountId) -> Option<Side> {
        if account == &self.creator {
            Some(Side::A)
        } else if account == &self.opponent {
            Some(Side::B)
        } else {
            None
        }
    }

    pub fn account_of(&self, side: Side) -> &AccountId {
        match side {
            Side::A => &self.creator,
            Side::B => &self.opponent,
        }
    }

    pub fn remaining_mut(&mut self, side: Side) -> &mut u64 {
        match side {
            Side::A => &mut self.remaining_a,
            Side::B => &mut self.remaining_b,
        }
    }

    pub fn remaining(&self, side: Side) -> u64 {
        match side {
            Side::A => self.remaining_a,
            Side::B => self.remaining_b,
        }
    }

    pub fn next_nonce_mut(&mut self, side: Side) -> &mut u64 {
        match side {
            Side::A => &mut self.next_nonce_a,
            Side::B => &mut self.next_nonce_b,
        }
    }
}

#[allow(dead_code)]
pub fn exchange_name(e: Exchange) -> &'static str {
    match e {
        Exchange::AttackerWins => "attacker_wins",
        Exchange::DefenderWins => "defender_wins",
        Exchange::BothEliminated => "both_eliminated",
    }
}

#[allow(dead_code)]
pub fn reexport_arbiter_resolve(a: Rank, d: Rank) -> Exchange {
    arbiter::resolve(a, d)
}

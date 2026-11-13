//! Settlement. The contract opens hash commitments; it never decrypts.
//!
//! `submit_setup` checks `sha256(rank || salt)`, `COMPOSITION`, and the
//! fight log. **The loser is verified even after the win is awarded.**
//! That branch is the audit, the void detector, and Alice’s Five-star.
//! Do not delete the second side's check.

use crate::arbiter::Rank;
use crate::setup::PIECES_PER_SIDE;

/// True when a claimed flip list has 21 pieces. Rank values are not opened here.
pub fn claimed_len_ok(pieces: &[(Rank, u8, u8, [u8; 32])]) -> bool {
    pieces.len() == PIECES_PER_SIDE
}

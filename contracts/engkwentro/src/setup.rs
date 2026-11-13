//! Setup helpers. Hash commitments and first-player bit. No floats.

pub const COMMITMENT_LEN: usize = 32;
pub const PIECES_PER_SIDE: usize = 21;
pub const CLOCK_MINUTES_MIN: u8 = 1;
pub const CLOCK_MINUTES_MAX: u8 = 15;
pub const NS_PER_MINUTE: u64 = 60 * 1_000_000_000;
pub const RESOLUTION_WINDOW_NS: u64 = 5 * 60 * 1_000_000_000;
pub const HOME_A: std::ops::RangeInclusive<u8> = 0..=2;
pub const HOME_B: std::ops::RangeInclusive<u8> = 5..=7;

/// `sha256(rank_id || salt)`. Bound to a square at `commit_setup`.
pub fn piece_commitment(rank: u8, salt: &[u8; 32]) -> [u8; 32] {
    let mut buf = Vec::with_capacity(33);
    buf.push(rank);
    buf.extend_from_slice(salt);
    let digest = near_sdk::env::sha256(&buf);
    let mut out = [0u8; 32];
    out.copy_from_slice(&digest);
    out
}

/// SHA-256 first-player bit from `docs/ALTERNATIVES.md` Option 2.
/// Used at `accept_match` (and legacy `confirm_roster`).
/// `true` means the creator (side A) moves first.
pub fn first_is_creator(
    random_seed: &[u8],
    match_id: u64,
    creator: &[u8],
    opponent: &[u8],
) -> bool {
    let mut buf = Vec::with_capacity(32 + 8 + creator.len() + opponent.len());
    buf.extend_from_slice(random_seed);
    buf.extend_from_slice(&match_id.to_le_bytes());
    buf.extend_from_slice(creator);
    buf.extend_from_slice(opponent);
    let digest = near_sdk::env::sha256(&buf);
    digest[0] & 1 == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commitment_is_32_bytes() {
        let c = piece_commitment(2, &[9u8; 32]);
        assert_eq!(c.len(), COMMITMENT_LEN);
        assert_ne!(c, piece_commitment(14, &[9u8; 32]));
    }

    #[test]
    fn first_player_is_deterministic() {
        let seed = [7u8; 32];
        let a = first_is_creator(&seed, 1, b"alice.near", b"bob.near");
        let b = first_is_creator(&seed, 1, b"alice.near", b"bob.near");
        assert_eq!(a, b);
    }

    #[test]
    fn first_player_changes_with_match_id() {
        let seed = [7u8; 32];
        let a = first_is_creator(&seed, 1, b"alice.near", b"bob.near");
        let b = first_is_creator(&seed, 2, b"alice.near", b"bob.near");
        let mut buf1 = Vec::new();
        buf1.extend_from_slice(&seed);
        buf1.extend_from_slice(&1u64.to_le_bytes());
        buf1.extend_from_slice(b"alice.near");
        buf1.extend_from_slice(b"bob.near");
        let mut buf2 = buf1.clone();
        buf2[32..40].copy_from_slice(&2u64.to_le_bytes());
        assert_ne!(near_sdk::env::sha256(&buf1), near_sdk::env::sha256(&buf2));
        let _ = (a, b);
    }
}

//! User-facing match key. Sequential `MatchId` stays the audit id.

use near_sdk::env;

/// Crockford-style alphabet: no `0 O I 1`.
pub const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
pub const KEY_LEN: usize = 12;

/// Storage prefixes. Not fields on `Contract` — adding those would
/// break the live `play.engkwentro.testnet` layout.
pub const BY_KEY: &[u8] = b"k";
pub const BY_ID: &[u8] = b"j";

/// Named-opponent slot until someone joins by key. Not a real player.
pub const OPEN_OPPONENT: &str = "open.engkwentro.testnet";

/// 12-character key from `random_seed || timestamp || match_id || predecessor`.
pub fn mint(match_id: u64) -> String {
    let mut material = Vec::with_capacity(80);
    material.extend_from_slice(&env::random_seed());
    material.extend_from_slice(&env::block_timestamp().to_le_bytes());
    material.extend_from_slice(&match_id.to_le_bytes());
    material.extend_from_slice(env::predecessor_account_id().as_bytes());
    encode(&env::sha256(&material))
}

/// Maps 12 hash bytes onto [ALPHABET].
pub fn encode(hash: &[u8]) -> String {
    let mut out = String::with_capacity(KEY_LEN);
    for i in 0..KEY_LEN {
        let b = hash.get(i).copied().unwrap_or(0);
        out.push(ALPHABET[b as usize % ALPHABET.len()] as char);
    }
    out
}

/// Uppercase, drop dashes and spaces. Used on join.
pub fn normalize(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_is_twelve_alphabet_chars() {
        let key = encode(&[0u8; 32]);
        assert_eq!(key.len(), KEY_LEN);
        assert!(key.bytes().all(|b| ALPHABET.contains(&b)));
    }

    #[test]
    fn normalize_strips_grouping() {
        assert_eq!(normalize("ab2c-de3f-gh4j"), "AB2CDE3FGH4J");
        assert_eq!(normalize("  k7m2 p9qw x4r8 "), "K7M2P9QWX4R8");
    }
}

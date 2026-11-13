//! Storage deposit helpers. Storage on NEAR is a refundable deposit.

use near_sdk::NearToken;

/// Minimum storage deposit attached to `create_match` in v0.1.0.
pub const MATCH_STORAGE_DEPOSIT: NearToken = NearToken::from_millinear(50);

#[allow(dead_code)]
pub fn refund_on_resolution() {
    // Reclaim after `claim_payout` once storage accounting is measured.
}

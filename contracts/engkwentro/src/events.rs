//! NEP-297 events. Standard `engkwentro`, version `1.0.0`.

use crate::state::{MatchId, Side};
use near_sdk::env;

pub const STANDARD: &str = "engkwentro";
pub const VERSION: &str = "1.0.0";

fn emit(event: &str, data: &str) {
    env::log_str(&format!(
        "EVENT_JSON:{{\"standard\":\"{STANDARD}\",\"version\":\"{VERSION}\",\"event\":\"{event}\",\"data\":{data}}}"
    ));
}

pub fn match_created(match_id: MatchId, join_key: &str) {
    emit(
        "match_created",
        &format!("{{\"match_id\":{match_id},\"join_key\":\"{join_key}\"}}"),
    );
}

pub fn match_accepted(match_id: MatchId) {
    emit("match_accepted", &format!("{{\"match_id\":{match_id}}}"));
}

pub fn setup_committed(match_id: MatchId, side: Side) {
    let s = match side {
        Side::A => "A",
        Side::B => "B",
    };
    emit(
        "setup_committed",
        &format!("{{\"match_id\":{match_id},\"side\":\"{s}\"}}"),
    );
}

pub fn roster_confirmed(match_id: MatchId, first: Side) {
    let s = match first {
        Side::A => "A",
        Side::B => "B",
    };
    emit(
        "roster_confirmed",
        &format!("{{\"match_id\":{match_id},\"first\":\"{s}\"}}"),
    );
}

pub fn waiting_for_arbiter(match_id: MatchId, from: u8, to: u8) {
    emit(
        "waiting_for_arbiter",
        &format!("{{\"match_id\":{match_id},\"from\":{from},\"to\":{to}}}"),
    );
}

pub fn match_ended(match_id: MatchId) {
    emit("match_ended", &format!("{{\"match_id\":{match_id}}}"));
}

pub fn match_settled(match_id: MatchId) {
    emit("match_settled", &format!("{{\"match_id\":{match_id}}}"));
}

pub fn match_voided(match_id: MatchId) {
    emit("match_voided", &format!("{{\"match_id\":{match_id}}}"));
}

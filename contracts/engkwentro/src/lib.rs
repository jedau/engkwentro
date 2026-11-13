//! Engkwentro match contract v0.1.0.
//!
//! v0.1.0 match contract: setup, play, settlement. Vault/client are separate.

mod arbiter;
mod errors;
mod events;
mod gas;
mod join;
mod moves;
mod play;
mod settlement;
mod setup;
mod state;
mod storage;

#[cfg(test)]
mod cost_sim;
#[cfg(test)]
mod pipeline;

pub use arbiter::{ends_game, resolve, Exchange, Rank, COMPOSITION, MATRIX};
pub use errors::MatchError;
pub use state::{MatchId, MatchState, RulesetId, Side};

use gas::ActionKind;
use near_sdk::json_types::{U128, U64};
use near_sdk::store::LookupMap;
use near_sdk::{env, near, AccountId, NearToken, PanicOnDefault, Promise};
use setup::{
    first_is_creator, piece_commitment, CLOCK_MINUTES_MAX, CLOCK_MINUTES_MIN, COMMITMENT_LEN,
    HOME_A, HOME_B, NS_PER_MINUTE, PIECES_PER_SIDE, RESOLUTION_WINDOW_NS,
};
use state::{
    square_index, DrawReason, ForfeitCause, Match, Outcome, Placement, SettlementStatus,
    SignedMove, VoidReason, WinReason,
};

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Contract {
    next_match_id: u64,
    matches: LookupMap<u64, Match>,
    gas_stats: LookupMap<u8, gas::GasStat>,
}

#[near]
impl Contract {
    /// Pre: none. Post: ids start at 1. No privileged worker.
    /// Source: none. Deadline: none. Event: none.
    #[init]
    #[handle_result]
    pub fn init() -> Result<Self, MatchError> {
        Ok(Self {
            next_match_id: 1,
            matches: LookupMap::new(b"m"),
            gas_stats: LookupMap::new(b"g"),
        })
    }

    /// Pre: `clock_minutes` in 1..=15. `opponent` omitted = open challenge.
    /// Post: match in `Created`, not accepted. Source: none.
    /// Deadline: none. Event: `match_created`.
    #[payable]
    #[handle_result]
    pub fn create_match(
        &mut self,
        opponent: Option<AccountId>,
        stake: U128,
        ruleset: RulesetId,
        clock_minutes: u8,
    ) -> Result<(MatchId, String), MatchError> {
        let before = env::used_gas();
        if !matches!(ruleset, RulesetId::Standard) {
            return Err(MatchError::InvalidRuleset);
        }
        if !(CLOCK_MINUTES_MIN..=CLOCK_MINUTES_MAX).contains(&clock_minutes) {
            return Err(MatchError::InvalidClockMinutes);
        }
        let creator = env::predecessor_account_id();
        let open: AccountId = join::OPEN_OPPONENT.parse().unwrap();
        let opponent = match opponent {
            Some(o) if o == creator => return Err(MatchError::SelfMatch),
            Some(o) => o,
            None => open,
        };
        if stake.0 > 0 && env::attached_deposit().as_yoctonear() < stake.0 {
            return Err(MatchError::InsufficientDeposit);
        }
        let id = self.next_match_id;
        self.next_match_id = id.saturating_add(1);
        let clock_ns = u64::from(clock_minutes) * NS_PER_MINUTE;
        let record = Match {
            id,
            creator,
            opponent,
            accepted: false,
            stake: stake.0,
            ruleset,
            clock_ns,
            remaining_a: clock_ns,
            remaining_b: clock_ns,
            state: MatchState::Created,
            settlement: None,
            first: None,
            to_move: None,
            next_nonce_a: 0,
            next_nonce_b: 0,
            placements_a: None,
            placements_b: None,
            occupancy: [0; 72],
            history: Vec::new(),
            turn_started_at: 0,
            clocks_paused: false,
            draw_offered_by: None,
            claimed_a: false,
            claimed_b: false,
            verified_a: None,
            verified_b: None,
            paid: false,
            waiting_mover: None,
            pending_by: None,
            pending_exchange: None,
            pending_flag: false,
            resolution_deadline: 0,
            fight_log: Vec::new(),
            opened: [255; 43],
        };
        self.matches.insert(id, record);
        let join_key = self.store_join_key(id);
        events::match_created(id, &join_key);
        let _ = storage::MATCH_STORAGE_DEPOSIT;
        gas::record(
            &mut self.gas_stats,
            ActionKind::CreateMatch,
            env::used_gas().saturating_sub(before),
        );
        Ok((id, join_key))
    }

    /// Looks up the sequential audit id from a typed join key.
    pub fn get_match_id_by_key(&self, join_key: String) -> Option<MatchId> {
        let key = join::normalize(&join_key);
        if key.len() != join::KEY_LEN {
            return None;
        }
        let by_key: LookupMap<String, MatchId> = LookupMap::new(join::BY_KEY);
        by_key.get(&key).copied()
    }

    /// Join key for [match_id], if this match was created after keys shipped.
    pub fn get_join_key(&self, match_id: MatchId) -> Option<String> {
        let by_id: LookupMap<MatchId, String> = LookupMap::new(join::BY_ID);
        by_id.get(&match_id).cloned()
    }

    /// Accept via the shareable key. Sequential id still binds the record.
    ///
    /// Payable: when the match has a non-zero stake, the joiner must attach
    /// at least that much NEAR (same as the creator did at `create_match`).
    #[payable]
    #[handle_result]
    pub fn accept_match_by_key(&mut self, join_key: String) -> Result<MatchId, MatchError> {
        let Some(id) = self.get_match_id_by_key(join_key) else {
            return Err(MatchError::UnknownMatch);
        };
        self.accept_match(id)?;
        Ok(id)
    }

    fn store_join_key(&mut self, id: MatchId) -> String {
        let mut by_key: LookupMap<String, MatchId> = LookupMap::new(join::BY_KEY);
        let mut by_id: LookupMap<MatchId, String> = LookupMap::new(join::BY_ID);
        let mut key = join::mint(id);
        let mut n = 0u8;
        while by_key.contains_key(&key) && n < 8 {
            n += 1;
            let mut extra = key.into_bytes();
            extra.push(n);
            key = join::encode(&env::sha256(&extra));
        }
        by_key.insert(key.clone(), id);
        by_id.insert(id, key.clone());
        key
    }

    /// Pre: caller is the stored opponent, state `Created`, not yet accepted.
    /// Post: `accepted = true`, `first` set (light/dark for setup). Binds the
    /// opponent. Deadline: none. Event: `match_accepted`.
    ///
    /// Payable: non-zero `m.stake` requires `attached_deposit >= stake`
    /// so the pot is `2 × stake` before play starts.
    #[payable]
    #[handle_result]
    pub fn accept_match(&mut self, match_id: MatchId) -> Result<(), MatchError> {
        let before = env::used_gas();
        let caller = env::predecessor_account_id();
        {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            if m.state != MatchState::Created {
                return Err(MatchError::WrongState);
            }
            if m.accepted {
                return Err(MatchError::AlreadyAccepted);
            }
            if caller == m.creator {
                return Err(MatchError::SelfMatch);
            }
            if m.stake > 0 && env::attached_deposit().as_yoctonear() < m.stake {
                return Err(MatchError::InsufficientDeposit);
            }
            let open: AccountId = join::OPEN_OPPONENT.parse().unwrap();
            if m.opponent == open {
                m.opponent = caller;
            } else if caller != m.opponent {
                return Err(MatchError::Unauthorized);
            }
            m.accepted = true;
            // Kickoff colour before setup so both phones paint stable light/dark.
            // `to_move` stays unset until `confirm_roster`.
            if m.first.is_none() {
                let seed = env::random_seed();
                let creator_first = first_is_creator(
                    &seed,
                    match_id,
                    m.creator.as_str().as_bytes(),
                    m.opponent.as_str().as_bytes(),
                );
                m.first = Some(if creator_first { Side::A } else { Side::B });
            }
        }
        events::match_accepted(match_id);
        gas::record(
            &mut self.gas_stats,
            ActionKind::AcceptMatch,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// Pre: caller is a player, match accepted, state `Created`, this side has no setup.
    /// Post: 21 sealed placements stored. Event: `setup_committed`.
    #[handle_result]
    pub fn commit_setup(
        &mut self,
        match_id: MatchId,
        placements: Vec<(u8, u8, Vec<u8>)>,
    ) -> Result<(), MatchError> {
        let before = env::used_gas();
        let caller = env::predecessor_account_id();
        let side = {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            if m.state != MatchState::Created {
                return Err(MatchError::WrongState);
            }
            if !m.accepted {
                return Err(MatchError::NotAccepted);
            }
            let Some(side) = m.side_of(&caller) else {
                return Err(MatchError::NotPlayer);
            };
            let already = match side {
                Side::A => m.placements_a.is_some(),
                Side::B => m.placements_b.is_some(),
            };
            if already {
                return Err(MatchError::SetupAlreadyCommitted);
            }
            let parsed = parse_placements(side, placements)?;
            match side {
                Side::A => m.placements_a = Some(parsed),
                Side::B => m.placements_b = Some(parsed),
            }
            side
        };
        events::setup_committed(match_id, side);
        gas::record(
            &mut self.gas_stats,
            ActionKind::CommitSetup,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// Pre: caller is a player, both hash-setups present, state `Created`.
    /// Post: occupancy filled, `to_move` = existing `first`, state `Committed`.
    /// Event: `roster_confirmed`. Composition is audited at `submit_setup`.
    /// First mover is normally set at `accept_match`; legacy matches without
    /// `first` still roll here.
    #[handle_result]
    pub fn confirm_roster(&mut self, match_id: MatchId) -> Result<(), MatchError> {
        let before = env::used_gas();
        let caller = env::predecessor_account_id();
        let first = {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            if m.side_of(&caller).is_none() {
                return Err(MatchError::NotPlayer);
            }
            if m.state != MatchState::Created || !m.accepted {
                return Err(MatchError::WrongState);
            }
            let Some(ref a) = m.placements_a else {
                return Err(MatchError::SetupsIncomplete);
            };
            let Some(ref b) = m.placements_b else {
                return Err(MatchError::SetupsIncomplete);
            };
            let mut occupancy = [0u8; 72];
            fill_occupancy(&mut occupancy, a, Side::A)?;
            fill_occupancy(&mut occupancy, b, Side::B)?;
            let first = if let Some(f) = m.first {
                f
            } else {
                let seed = env::random_seed();
                let creator_first = first_is_creator(
                    &seed,
                    match_id,
                    m.creator.as_str().as_bytes(),
                    m.opponent.as_str().as_bytes(),
                );
                if creator_first {
                    Side::A
                } else {
                    Side::B
                }
            };
            m.occupancy = occupancy;
            m.first = Some(first);
            m.to_move = Some(first);
            m.state = MatchState::Committed;
            // First turn starts now; clients time from get_sync.
            m.turn_started_at = env::block_timestamp();
            m.clocks_paused = false;
            first
        };
        events::roster_confirmed(match_id, first);
        gas::record(
            &mut self.gas_stats,
            ActionKind::ConfirmRoster,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// Pre: `Committed` or `InProgress` (or `Breakthrough` reply). Exactly one move.
    /// Post: quiet move applied, or `WaitingForArbiter`. NEP-413 / ed25519 inline.
    ///
    /// `think_ns` is the mover's claim of how long the turn was visibly
    /// theirs: from their phone showing it until they committed to the move.
    /// They are charged that instead of the whole block-to-block turn, with
    /// at most [`play::LAG_CAP_NS`] credited. Omitted = charged to the block.
    /// The next turn always starts at the block, so network time is charged
    /// to nobody.
    #[handle_result]
    pub fn apply_moves(
        &mut self,
        match_id: MatchId,
        moves: Vec<SignedMove>,
        think_ns: Option<U64>,
    ) -> Result<(), MatchError> {
        let before = env::used_gas();
        let now = env::block_timestamp();
        let caller = env::predecessor_account_id();
        if moves.len() != 1 {
            return Err(MatchError::EmptyBatch);
        }
        let mv = moves.into_iter().next().unwrap();
        if mv.match_id != match_id {
            return Err(MatchError::IllegalMove);
        }
        let ended = {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            let charge_at = play::charge_until(m.turn_started_at, now, think_ns.map(|t| t.0));
            apply_one(m, &mv, &caller, now, charge_at)?
        };
        if ended {
            events::match_ended(match_id);
        }
        gas::record(
            &mut self.gas_stats,
            ActionKind::ApplyMoves,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// Player report of a 2PC fight. Applied when the other side reports the same pair.
    #[handle_result]
    pub fn resolve_challenge(
        &mut self,
        match_id: MatchId,
        exchange: Exchange,
        flag_captured: bool,
    ) -> Result<(), MatchError> {
        let before = env::used_gas();
        let now = env::block_timestamp();
        let ended = report_wait(self, match_id, Some(exchange), flag_captured, now)?;
        if ended {
            events::match_ended(match_id);
        }
        gas::record(
            &mut self.gas_stats,
            ActionKind::ResolveChallenge,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// Player report of a home-row arrival. Applied when the other side agrees.
    #[handle_result]
    pub fn confirm_arrival(&mut self, match_id: MatchId, is_flag: bool) -> Result<(), MatchError> {
        let before = env::used_gas();
        let now = env::block_timestamp();
        let ended = report_wait(self, match_id, None, is_flag, now)?;
        if ended {
            events::match_ended(match_id);
        }
        gas::record(
            &mut self.gas_stats,
            ActionKind::ConfirmArrival,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// Pre: caller is to-move, play live, before they move.
    #[handle_result]
    pub fn offer_draw(&mut self, match_id: MatchId) -> Result<(), MatchError> {
        let before = env::used_gas();
        let caller = env::predecessor_account_id();
        {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            let Some(side) = m.side_of(&caller) else {
                return Err(MatchError::NotPlayer);
            };
            if m.to_move != Some(side) || !play_live(&m.state) {
                return Err(MatchError::WrongState);
            }
            m.draw_offered_by = Some(side);
        }
        gas::record(
            &mut self.gas_stats,
            ActionKind::OfferDraw,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// Pre: a live offer from the other side.
    #[handle_result]
    pub fn accept_draw(&mut self, match_id: MatchId) -> Result<(), MatchError> {
        let before = env::used_gas();
        let caller = env::predecessor_account_id();
        let now = env::block_timestamp();
        {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            let Some(side) = m.side_of(&caller) else {
                return Err(MatchError::NotPlayer);
            };
            match m.draw_offered_by {
                Some(offerer) if offerer != side => {}
                _ => return Err(MatchError::WrongState),
            }
            play::end_match(
                m,
                Outcome::Draw {
                    reason: DrawReason::Agreement,
                },
                now,
            );
        }
        events::match_ended(match_id);
        gas::record(
            &mut self.gas_stats,
            ActionKind::AcceptDraw,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    #[handle_result]
    pub fn resign(&mut self, match_id: MatchId) -> Result<(), MatchError> {
        let before = env::used_gas();
        let caller = env::predecessor_account_id();
        let now = env::block_timestamp();
        {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            let Some(side) = m.side_of(&caller) else {
                return Err(MatchError::NotPlayer);
            };
            if !play_live(&m.state) {
                return Err(MatchError::WrongState);
            }
            play::end_match(
                m,
                Outcome::Win {
                    winner: moves::other(side),
                    reason: WinReason::Resignation,
                },
                now,
            );
        }
        events::match_ended(match_id);
        gas::record(
            &mut self.gas_stats,
            ActionKind::Resign,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// Permissionless. Ends the match if the side-to-move clock has expired.
    #[handle_result]
    pub fn claim_timeout(&mut self, match_id: MatchId) -> Result<(), MatchError> {
        let before = env::used_gas();
        let now = env::block_timestamp();
        {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            if m.clocks_paused || matches!(m.state, MatchState::WaitingForArbiter { .. }) {
                return Err(MatchError::WrongState);
            }
            let Some(side) = m.to_move else {
                return Err(MatchError::WrongState);
            };
            // A move tapped before the flag fell may still be in flight, so the
            // flag only becomes claimable once the lag window has also passed.
            let elapsed = play::charged_elapsed(m.turn_started_at, now);
            if elapsed < m.remaining(side).saturating_add(play::LAG_CAP_NS) {
                return Err(MatchError::WrongState);
            }
            play::timeout_loser(m, side, now);
        }
        events::match_ended(match_id);
        gas::record(
            &mut self.gas_stats,
            ActionKind::ClaimTimeout,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    #[handle_result]
    pub fn submit_setup(
        &mut self,
        match_id: MatchId,
        pieces: Vec<(Rank, u8, u8, [u8; 32])>,
    ) -> Result<(), MatchError> {
        let before = env::used_gas();
        let caller = env::predecessor_account_id();
        if !settlement::claimed_len_ok(&pieces) {
            return Err(MatchError::InvalidSetup);
        }
        {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            if !matches!(m.state, MatchState::Ended { .. }) {
                return Err(MatchError::NotEnded);
            }
            let Some(side) = m.side_of(&caller) else {
                return Err(MatchError::NotPlayer);
            };
            let stored = match side {
                Side::A => m.placements_a.as_deref(),
                Side::B => m.placements_b.as_deref(),
            };
            let Some(stored) = stored else {
                return Err(MatchError::SetupsIncomplete);
            };
            let ok = openings_match(stored, &pieces);
            let base: usize = match side {
                Side::A => 1,
                Side::B => 22,
            };
            if ok {
                for (i, p) in stored.iter().enumerate() {
                    if let Some((rank, _, _, _)) = pieces
                        .iter()
                        .find(|(_, f, r, _)| *f == p.file && *r == p.board_rank)
                    {
                        m.opened[base + i] = *rank as u8;
                    }
                }
            }
            match side {
                Side::A => {
                    m.claimed_a = true;
                    m.verified_a = Some(ok);
                }
                Side::B => {
                    m.claimed_b = true;
                    m.verified_b = Some(ok);
                }
            }
            if m.verified_a == Some(true) && m.verified_b == Some(true) {
                replay_fights(m);
            }
        }
        gas::record(
            &mut self.gas_stats,
            ActionKind::SubmitSetup,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// The loser is verified even after the win is awarded. On-chain openings
    /// already ran in `submit_setup`; this is a no-op if that side is set.
    #[handle_result]
    pub fn verify_setup(
        &mut self,
        match_id: MatchId,
        side: Side,
        _valid: bool,
    ) -> Result<(), MatchError> {
        let before = env::used_gas();
        {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            if !matches!(m.settlement, Some(SettlementStatus::AwaitingFlip { .. })) {
                return Err(MatchError::WrongState);
            }
            let already = match side {
                Side::A => m.verified_a,
                Side::B => m.verified_b,
            };
            if already.is_none() {
                return Err(MatchError::FlipIncomplete);
            }
        }
        gas::record(
            &mut self.gas_stats,
            ActionKind::VerifySetup,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    /// Permissionless. Resolves `AwaitingFlip` from the two worker bools or timeout.
    #[handle_result]
    pub fn settle(&mut self, match_id: MatchId) -> Result<(), MatchError> {
        let before = env::used_gas();
        let now = env::block_timestamp();
        let status = {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            let Some(SettlementStatus::AwaitingFlip { deadline }) = m.settlement else {
                return Err(MatchError::WrongState);
            };
            let a = m.verified_a;
            let b = m.verified_b;
            let timed_out = now >= deadline;
            match (a, b, timed_out) {
                (Some(true), Some(true), _) => {
                    m.settlement = Some(SettlementStatus::Settled);
                    SettlementStatus::Settled
                }
                (Some(false), Some(false), _) | (None, None, true) => {
                    play::void_match(m, now);
                    SettlementStatus::Voided
                }
                (Some(false), Some(true), _) | (None, Some(true), true) => {
                    play::forfeit_side(m, Side::A, now, ForfeitCause::SettlementTimeout);
                    SettlementStatus::Forfeited { by: Side::A }
                }
                (Some(true), Some(false), _) | (Some(true), None, true) => {
                    play::forfeit_side(m, Side::B, now, ForfeitCause::SettlementTimeout);
                    SettlementStatus::Forfeited { by: Side::B }
                }
                (Some(false), None, true) => {
                    play::void_match(m, now);
                    SettlementStatus::Voided
                }
                (None, Some(false), true) => {
                    play::void_match(m, now);
                    SettlementStatus::Voided
                }
                _ => return Err(MatchError::FlipIncomplete),
            }
        };
        match status {
            SettlementStatus::Settled => events::match_settled(match_id),
            SettlementStatus::Voided => events::match_voided(match_id),
            _ => {}
        }
        gas::record(
            &mut self.gas_stats,
            ActionKind::Settle,
            env::used_gas().saturating_sub(before),
        );
        Ok(())
    }

    #[handle_result]
    pub fn claim_payout(&mut self, match_id: MatchId) -> Result<(), MatchError> {
        let before = env::used_gas();
        let (winner, stake, creator, opponent, settlement) = {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            match m.settlement {
                Some(SettlementStatus::Settled)
                | Some(SettlementStatus::Forfeited { .. })
                | Some(SettlementStatus::Voided) => {}
                _ => return Err(MatchError::WrongState),
            }
            if m.paid {
                return Err(MatchError::AlreadyPaid);
            }
            m.paid = true;
            let winner = match m.state {
                MatchState::Ended {
                    outcome: Outcome::Win { winner, .. },
                } => Some(winner),
                _ => None,
            };
            (
                winner,
                m.stake,
                m.creator.clone(),
                m.opponent.clone(),
                m.settlement,
            )
        };
        if stake == 0 {
            gas::record(
                &mut self.gas_stats,
                ActionKind::ClaimPayout,
                env::used_gas().saturating_sub(before),
            );
            return Ok(());
        }
        let result = match settlement {
            Some(SettlementStatus::Voided) => Ok(()),
            Some(SettlementStatus::Settled) | Some(SettlementStatus::Forfeited { .. }) => {
                if let Some(w) = winner {
                    let (payout, _) = play::payout_amounts(stake);
                    let dest = if w == Side::A { creator } else { opponent };
                    let _ = Promise::new(dest).transfer(NearToken::from_yoctonear(payout));
                } else {
                    let _ =
                        Promise::new(creator.clone()).transfer(NearToken::from_yoctonear(stake));
                    let _ = Promise::new(opponent).transfer(NearToken::from_yoctonear(stake));
                }
                Ok(())
            }
            _ => Err(MatchError::WrongState),
        };
        gas::record(
            &mut self.gas_stats,
            ActionKind::ClaimPayout,
            env::used_gas().saturating_sub(before),
        );
        result
    }

    pub fn get_next_match_id(&self) -> MatchId {
        self.next_match_id
    }

    pub fn get_match_state(&self, match_id: MatchId) -> Option<String> {
        self.matches.get(&match_id).map(|m| match m.state {
            MatchState::Created => "Created".to_string(),
            MatchState::Committed => "Committed".to_string(),
            MatchState::InProgress => "InProgress".to_string(),
            MatchState::WaitingForArbiter { .. } => "WaitingForArbiter".to_string(),
            MatchState::Breakthrough { .. } => "Breakthrough".to_string(),
            MatchState::Ended { .. } => "Ended".to_string(),
        })
    }

    /// `(kind, winner_or_empty, reason)` when `Ended`. `kind` is `Win` /
    /// `Draw` / `Void`. Winner is `"A"` / `"B"` for a win, else `""`.
    pub fn get_outcome(&self, match_id: MatchId) -> Option<(String, String, String)> {
        let m = self.matches.get(&match_id)?;
        let MatchState::Ended { outcome } = &m.state else {
            return None;
        };
        Some(match outcome {
            Outcome::Win { winner, reason } => (
                "Win".to_string(),
                match winner {
                    Side::A => "A".to_string(),
                    Side::B => "B".to_string(),
                },
                win_reason_label(*reason),
            ),
            Outcome::Draw { reason } => (
                "Draw".to_string(),
                String::new(),
                match reason {
                    DrawReason::Agreement => "Agreement".to_string(),
                    DrawReason::Repetition => "Repetition".to_string(),
                },
            ),
            Outcome::Void { reason } => (
                "Void".to_string(),
                String::new(),
                match reason {
                    VoidReason::MutualSettlementFailure => "MutualSettlementFailure".to_string(),
                },
            ),
        })
    }

    pub fn get_settlement(&self, match_id: MatchId) -> Option<String> {
        self.matches.get(&match_id).and_then(|m| {
            m.settlement.as_ref().map(|s| match s {
                SettlementStatus::AwaitingFlip { .. } => "AwaitingFlip".to_string(),
                SettlementStatus::Settled => "Settled".to_string(),
                SettlementStatus::Forfeited { .. } => "Forfeited".to_string(),
                SettlementStatus::Voided => "Voided".to_string(),
            })
        })
    }

    /// Piece-index → rank discriminant. `255` is still hidden.
    /// Index 0 unused; `1..=21` A, `22..=42` B.
    pub fn get_opened(&self, match_id: MatchId) -> Option<Vec<u8>> {
        self.matches.get(&match_id).map(|m| m.opened.to_vec())
    }

    /// Permissionless. Mute side in `WaitingForArbiter` forfeits after the window.
    #[handle_result]
    pub fn claim_resolution_timeout(&mut self, match_id: MatchId) -> Result<(), MatchError> {
        let now = env::block_timestamp();
        {
            let Some(m) = self.matches.get_mut(&match_id) else {
                return Err(MatchError::UnknownMatch);
            };
            if !matches!(m.state, MatchState::WaitingForArbiter { .. }) {
                return Err(MatchError::WrongState);
            }
            if now < m.resolution_deadline {
                return Err(MatchError::WrongState);
            }
            match m.pending_by {
                None => play::void_match(m, now),
                Some(by) => {
                    play::forfeit_side(m, moves::other(by), now, ForfeitCause::SettlementTimeout)
                }
            }
        }
        events::match_ended(match_id);
        Ok(())
    }

    pub fn get_board_for(&self, match_id: MatchId) -> Option<Vec<u8>> {
        self.matches.get(&match_id).map(|m| m.occupancy.to_vec())
    }

    /// Chess clocks for the client UI.
    ///
    /// `(remaining_a_ns, remaining_b_ns, turn_started_at_ns, chain_now_ns,
    /// clocks_paused, to_move "A"|"B"|"")`. `remaining_*` are **live** at
    /// `chain_now` (side-to-move elapsed already subtracted). Clients tick
    /// only wall time since fetch — do not subtract turn elapsed again.
    /// Prefer [`Self::get_sync`] for clients: this view alone can disagree
    /// with `get_play` across blocks. Kept for diagnostics and tests.
    pub fn get_clocks(&self, match_id: MatchId) -> Option<(u64, u64, u64, u64, bool, String)> {
        self.matches.get(&match_id).map(|m| {
            let now = env::block_timestamp();
            let (remaining_a, remaining_b) = play::live_banks(m, now);
            let to_move = match m.to_move {
                Some(Side::A) => "A".to_string(),
                Some(Side::B) => "B".to_string(),
                None => String::new(),
            };
            (
                remaining_a,
                remaining_b,
                m.turn_started_at,
                now,
                m.clocks_paused,
                to_move,
            )
        })
    }

    /// Everything a phone paints, read from one block.
    ///
    /// `(play, clocks, seats, occupancy)` where
    /// - `play` is [`Self::get_play`],
    /// - `clocks` is `(bank_a_ns, bank_b_ns, turn_started_at_ns,
    ///   chain_now_ns, clocks_paused, block_height)`. Banks are **as
    ///   stored**: what each side had when the current turn started. Unlike
    ///   [`Self::get_clocks`] nothing is subtracted, so within a turn every
    ///   row carries the same three numbers and a client derives the running
    ///   clock as `bank - (now - turn_started_at)`,
    /// - `seats` is `(creator, opponent, accepted, first "A"|"B"|"",
    ///   setup_a_committed, setup_b_committed)`,
    /// - `occupancy` is [`Self::get_board_for`].
    ///
    /// Clients must use this instead of the separate views: those can answer
    /// from different blocks, which paints a turn and a clock that never
    /// co-existed. `block_height` lets a client drop a reply that is older
    /// than one it already applied.
    #[allow(clippy::type_complexity)]
    pub fn get_sync(
        &self,
        match_id: MatchId,
    ) -> Option<(
        (String, String, u64, u64, u8, u8),
        (u64, u64, u64, u64, bool, u64),
        (AccountId, AccountId, bool, String, bool, bool),
        Vec<u8>,
    )> {
        let play = self.get_play(match_id)?;
        let (creator, opponent, accepted, _stake, first) = self.get_match(match_id)?;
        let m = self.matches.get(&match_id)?;
        Some((
            play,
            (
                m.remaining_a,
                m.remaining_b,
                m.turn_started_at,
                env::block_timestamp(),
                m.clocks_paused,
                env::block_height(),
            ),
            (
                creator,
                opponent,
                accepted,
                first,
                m.placements_a.is_some(),
                m.placements_b.is_some(),
            ),
            m.occupancy.to_vec(),
        ))
    }

    /// Live play snapshot for two-device clients.
    /// `(state, to_move A/B/"", nonce_a, nonce_b, wait_from, wait_to)`.
    /// `wait_*` is 255 when not in `WaitingForArbiter`.
    pub fn get_play(&self, match_id: MatchId) -> Option<(String, String, u64, u64, u8, u8)> {
        self.matches.get(&match_id).map(|m| {
            let state = match m.state {
                MatchState::Created => "Created".to_string(),
                MatchState::Committed => "Committed".to_string(),
                MatchState::InProgress => "InProgress".to_string(),
                MatchState::WaitingForArbiter { .. } => "WaitingForArbiter".to_string(),
                MatchState::Breakthrough { .. } => "Breakthrough".to_string(),
                MatchState::Ended { .. } => "Ended".to_string(),
            };
            let to_move = match m.to_move {
                Some(Side::A) => "A".to_string(),
                Some(Side::B) => "B".to_string(),
                None => String::new(),
            };
            let (wait_from, wait_to) = match m.state {
                MatchState::WaitingForArbiter { from, to } => (from, to),
                _ => (255, 255),
            };
            (
                state,
                to_move,
                m.next_nonce_a,
                m.next_nonce_b,
                wait_from,
                wait_to,
            )
        })
    }

    /// `(creator, opponent, accepted, stake, first "A"|"B"|"")`.
    /// `first` is set at accept so clients can paint light/dark during setup.
    pub fn get_match(
        &self,
        match_id: MatchId,
    ) -> Option<(AccountId, AccountId, bool, u128, String)> {
        self.matches.get(&match_id).map(|m| {
            let first = match m.first {
                Some(Side::A) => "A".to_string(),
                Some(Side::B) => "B".to_string(),
                None => String::new(),
            };
            (
                m.creator.clone(),
                m.opponent.clone(),
                m.accepted,
                m.stake,
                first,
            )
        })
    }

    pub fn get_gas_stats(&self, kind: u8) -> Option<(u64, u64, u64)> {
        self.gas_stats
            .get(&kind)
            .map(|s| (s.calls, s.last_tgas, s.max_tgas))
    }

    pub fn storage_balance_of(&self, _account: AccountId) -> U128 {
        U128(0)
    }

    /// Settlement digest for a future registry `apply_result`. None if settlement is not terminal.
    pub fn get_ladder_input(
        &self,
        match_id: MatchId,
    ) -> Option<(AccountId, AccountId, String, String, bool)> {
        let m = self.matches.get(&match_id)?;
        let settlement = match m.settlement? {
            SettlementStatus::Settled => "Settled",
            SettlementStatus::Forfeited { .. } => "Forfeited",
            SettlementStatus::Voided => "Voided",
            SettlementStatus::AwaitingFlip { .. } => return None,
        };
        let (winner, draw) = match m.state {
            MatchState::Ended {
                outcome: Outcome::Win { winner, .. },
            } => (Some(winner), false),
            MatchState::Ended {
                outcome: Outcome::Draw { .. },
            } => (None, true),
            MatchState::Ended {
                outcome: Outcome::Void { .. },
            } => (None, false),
            _ => return None,
        };
        let first = match m.first? {
            Side::A => "A",
            Side::B => "B",
        };
        let winner_s = match winner {
            Some(Side::A) => "A".to_string(),
            Some(Side::B) => "B".to_string(),
            None => String::new(),
        };
        Some((
            m.creator.clone(),
            m.opponent.clone(),
            first.to_string(),
            format!("{settlement}:{winner_s}"),
            draw,
        ))
    }
}

fn play_live(state: &MatchState) -> bool {
    matches!(
        state,
        MatchState::Committed | MatchState::InProgress | MatchState::Breakthrough { .. }
    )
}

fn verify_signed_move(
    player: &AccountId,
    caller: &AccountId,
    mv: &SignedMove,
) -> Result<(), MatchError> {
    if caller == player {
        return Ok(());
    }
    if mv.signature.len() != 64 || mv.public_key.len() != 32 {
        return Err(MatchError::InvalidSignature);
    }
    let mut sig = [0u8; 64];
    sig.copy_from_slice(&mv.signature);
    let mut pk = [0u8; 32];
    pk.copy_from_slice(&mv.public_key);
    let msg = moves::move_message(mv.match_id, mv.from, mv.to, mv.nonce);
    if !env::ed25519_verify(&sig, &msg, &pk) {
        return Err(MatchError::InvalidSignature);
    }
    Ok(())
}

/// `now` is the block; `charge_at` is where the mover's clock stops
/// (see [`play::charge_until`]). Everything else is stamped with `now`.
fn apply_one(
    m: &mut Match,
    mv: &SignedMove,
    caller: &AccountId,
    now: u64,
    charge_at: u64,
) -> Result<bool, MatchError> {
    if matches!(
        m.state,
        MatchState::Ended { .. } | MatchState::WaitingForArbiter { .. }
    ) {
        return Err(MatchError::WrongState);
    }
    let Some(side) = m.to_move else {
        return Err(MatchError::WrongState);
    };
    let player = m.account_of(side).clone();
    verify_signed_move(&player, caller, mv)?;
    let expected = match side {
        Side::A => m.next_nonce_a,
        Side::B => m.next_nonce_b,
    };
    if mv.nonce != expected {
        return Err(MatchError::InvalidNonce);
    }
    *m.next_nonce_mut(side) = expected + 1;

    if let MatchState::Breakthrough { by, at, .. } = m.state {
        if play::charge_clock(m, side, charge_at).is_err() {
            play::timeout_loser(m, side, now);
            return Ok(true);
        }
        if mv.to == at && moves::occupant_side(m.occupancy[at as usize]) == Some(by) {
            if !moves::check_legal(&m.occupancy, side, mv.from, mv.to) {
                return Err(MatchError::IllegalMove);
            }
            enter_wait(m, mv.from, mv.to, side, now);
            events::waiting_for_arbiter(m.id, mv.from, mv.to);
            return Ok(false);
        }
        play::end_match(
            m,
            Outcome::Win {
                winner: by,
                reason: WinReason::FlagBreakthrough,
            },
            now,
        );
        return Ok(true);
    }

    if !matches!(m.state, MatchState::Committed | MatchState::InProgress) {
        return Err(MatchError::WrongState);
    }
    if play::charge_clock(m, side, charge_at).is_err() {
        play::timeout_loser(m, side, now);
        return Ok(true);
    }
    if !moves::check_legal(&m.occupancy, side, mv.from, mv.to) {
        return Err(MatchError::IllegalMove);
    }
    if let Some(offerer) = m.draw_offered_by {
        if offerer != side {
            m.draw_offered_by = None;
        }
    }
    let to_cell = m.occupancy[mv.to as usize];
    if moves::occupant_side(to_cell) == Some(moves::other(side)) {
        enter_wait(m, mv.from, mv.to, side, now);
        events::waiting_for_arbiter(m.id, mv.from, mv.to);
        return Ok(false);
    }
    moves::apply_quiet(&mut m.occupancy, mv.from, mv.to);
    if moves::on_enemy_home(side, mv.to) {
        enter_wait(m, mv.from, mv.to, side, now);
        events::waiting_for_arbiter(m.id, mv.from, mv.to);
        return Ok(false);
    }
    m.state = MatchState::InProgress;
    if play::check_repetition(m, moves::other(side), now) {
        return Ok(true);
    }
    play::finish_turn(m, side, now)?;
    Ok(matches!(m.state, MatchState::Ended { .. }))
}

fn finish_challenge(
    m: &mut Match,
    exchange: Exchange,
    flag_captured: bool,
    now: u64,
) -> Result<bool, MatchError> {
    let MatchState::WaitingForArbiter { from, to } = m.state else {
        return Err(MatchError::WrongState);
    };
    let Some(mover) = m.waiting_mover else {
        return Err(MatchError::WrongState);
    };
    m.fight_log.push((
        m.occupancy[from as usize],
        m.occupancy[to as usize],
        match exchange {
            Exchange::AttackerWins => 0,
            Exchange::DefenderWins => 1,
            Exchange::BothEliminated => 2,
        },
    ));
    moves::apply_exchange(&mut m.occupancy, from, to, exchange);
    m.history.clear();
    if flag_captured {
        play::end_match(
            m,
            Outcome::Win {
                winner: mover,
                reason: WinReason::FlagCaptured,
            },
            now,
        );
        m.waiting_mover = None;
        return Ok(true);
    }
    m.waiting_mover = None;
    if moves::on_enemy_home(mover, to)
        && moves::occupant_side(m.occupancy[to as usize]) == Some(mover)
    {
        enter_wait(m, to, to, mover, now);
        return Ok(false);
    }
    let incoming = moves::other(mover);
    if play::check_repetition(m, incoming, now) {
        return Ok(true);
    }
    play::finish_turn(m, mover, now)?;
    Ok(matches!(m.state, MatchState::Ended { .. }))
}

fn finish_arrival(m: &mut Match, is_flag: bool, now: u64) -> Result<bool, MatchError> {
    let MatchState::WaitingForArbiter { to, .. } = m.state else {
        return Err(MatchError::WrongState);
    };
    let Some(mover) = m.waiting_mover else {
        return Err(MatchError::WrongState);
    };
    if is_flag {
        m.state = MatchState::Breakthrough {
            by: mover,
            at: to,
            deadline: m.remaining(moves::other(mover)),
        };
        m.to_move = Some(moves::other(mover));
        m.turn_started_at = now;
        m.clocks_paused = false;
        m.waiting_mover = None;
        return Ok(false);
    }
    m.waiting_mover = None;
    if play::check_repetition(m, moves::other(mover), now) {
        return Ok(true);
    }
    play::finish_turn(m, mover, now)?;
    Ok(matches!(m.state, MatchState::Ended { .. }))
}

fn enter_wait(m: &mut Match, from: u8, to: u8, mover: Side, now: u64) {
    m.state = MatchState::WaitingForArbiter { from, to };
    m.waiting_mover = Some(mover);
    m.clocks_paused = true;
    m.pending_by = None;
    m.pending_exchange = None;
    m.pending_flag = false;
    m.resolution_deadline = now.saturating_add(RESOLUTION_WINDOW_NS);
}

fn report_wait(
    c: &mut Contract,
    match_id: MatchId,
    exchange: Option<Exchange>,
    flag: bool,
    now: u64,
) -> Result<bool, MatchError> {
    let Some(m) = c.matches.get_mut(&match_id) else {
        return Err(MatchError::UnknownMatch);
    };
    let caller = env::predecessor_account_id();
    let Some(side) = m.side_of(&caller) else {
        return Err(MatchError::NotPlayer);
    };
    if !matches!(m.state, MatchState::WaitingForArbiter { .. }) {
        return Err(MatchError::WrongState);
    }
    let dest = match m.state {
        MatchState::WaitingForArbiter { to, .. } => to,
        _ => return Err(MatchError::WrongState),
    };
    let fight = moves::occupant_side(m.occupancy[dest as usize]).is_some()
        && m.waiting_mover != moves::occupant_side(m.occupancy[dest as usize]);
    if fight && exchange.is_none() {
        return Err(MatchError::WrongState);
    }
    if !fight && exchange.is_some() {
        return Err(MatchError::WrongState);
    }
    match m.pending_by {
        None => {
            m.pending_by = Some(side);
            m.pending_exchange = exchange;
            m.pending_flag = flag;
            Ok(false)
        }
        Some(prev) if prev == side => Err(MatchError::WrongState),
        Some(_) if m.pending_exchange != exchange || m.pending_flag != flag => {
            play::void_match(m, now);
            Ok(true)
        }
        Some(_) => {
            m.pending_by = None;
            if let Some(ex) = exchange {
                finish_challenge(m, ex, flag, now)
            } else {
                finish_arrival(m, flag, now)
            }
        }
    }
}

fn replay_fights(m: &mut Match) {
    for (from_occ, to_occ, ex) in m.fight_log.iter().copied() {
        let ra = m.opened[from_occ as usize];
        let rd = m.opened[to_occ as usize];
        if ra > 14 || rd > 14 {
            continue;
        }
        let got = match resolve(Rank::from_u8(ra), Rank::from_u8(rd)) {
            Exchange::AttackerWins => 0,
            Exchange::DefenderWins => 1,
            Exchange::BothEliminated => 2,
        };
        if got != ex {
            if from_occ >= 22 {
                m.verified_b = Some(false);
            } else {
                m.verified_a = Some(false);
            }
        }
    }
}

fn openings_match(stored: &[Placement], pieces: &[(Rank, u8, u8, [u8; 32])]) -> bool {
    if pieces.len() != PIECES_PER_SIDE || stored.len() != PIECES_PER_SIDE {
        return false;
    }
    let mut counts = [0u8; 15];
    for (rank, file, board_rank, salt) in pieces {
        let want = piece_commitment(*rank as u8, salt);
        let Some(p) = stored
            .iter()
            .find(|p| p.file == *file && p.board_rank == *board_rank)
        else {
            return false;
        };
        if p.commitment != want {
            return false;
        }
        counts[*rank as usize] = counts[*rank as usize].saturating_add(1);
    }
    COMPOSITION.iter().all(|(r, n)| counts[*r as usize] == *n)
}

fn parse_placements(side: Side, raw: Vec<(u8, u8, Vec<u8>)>) -> Result<Vec<Placement>, MatchError> {
    if raw.len() != PIECES_PER_SIDE {
        return Err(MatchError::InvalidSetup);
    }
    let home = match side {
        Side::A => HOME_A,
        Side::B => HOME_B,
    };
    let mut seen = [false; 72];
    let mut out = Vec::with_capacity(PIECES_PER_SIDE);
    for (file, board_rank, commitment) in raw {
        let Some(idx) = square_index(file, board_rank) else {
            return Err(MatchError::InvalidSetup);
        };
        if !home.contains(&board_rank) {
            return Err(MatchError::InvalidSetup);
        }
        if seen[idx as usize] {
            return Err(MatchError::InvalidSetup);
        }
        seen[idx as usize] = true;
        if commitment.len() != COMMITMENT_LEN {
            return Err(MatchError::InvalidSetup);
        }
        let mut hash = [0u8; COMMITMENT_LEN];
        hash.copy_from_slice(&commitment);
        out.push(Placement {
            file,
            board_rank,
            commitment: hash,
        });
    }
    Ok(out)
}

fn fill_occupancy(
    occupancy: &mut [u8; 72],
    placements: &[Placement],
    side: Side,
) -> Result<(), MatchError> {
    for (i, p) in placements.iter().enumerate() {
        let Some(idx) = square_index(p.file, p.board_rank) else {
            return Err(MatchError::InvalidSetup);
        };
        if occupancy[idx as usize] != 0 {
            return Err(MatchError::InvalidSetup);
        }
        occupancy[idx as usize] = match side {
            Side::A => (i as u8) + 1,
            Side::B => (i as u8) + 22,
        };
    }
    Ok(())
}

fn win_reason_label(reason: WinReason) -> String {
    match reason {
        WinReason::FlagCaptured => "FlagCaptured".to_string(),
        WinReason::FlagBreakthrough => "FlagBreakthrough".to_string(),
        WinReason::Resignation => "Resignation".to_string(),
        WinReason::Immobilised => "Immobilised".to_string(),
        WinReason::Timeout => "Timeout".to_string(),
        WinReason::OpponentForfeited(ForfeitCause::InvalidSetup) => {
            "OpponentForfeited(InvalidSetup)".to_string()
        }
        WinReason::OpponentForfeited(ForfeitCause::SettlementTimeout) => {
            "OpponentForfeited(SettlementTimeout)".to_string()
        }
    }
}

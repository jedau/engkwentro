//! The arbiter: a pure rank-comparison function.
//!
//! Nothing here touches storage, `env`, or `self`. The module compiles without
//! `near-sdk`, which is what makes the 225-case matrix cheap to run and what
//! keeps the rules honest — there is exactly one implementation of the table.
//!
//! Rules: `docs/RULES.md` §6. Check order is FLG, then SPY, then the numeric
//! ladder. Do not reorder the match arms: the FLG and SPY cases sit above the
//! ladder precisely because their discriminants sort below the officers.
//!
//! `MATRIX` below is the **source of truth**. `scripts/gen_arbiter_dart.sh`
//! generates `client/lib/arbiter.g.dart` from it and a test fails if the
//! generated file is stale. The contract is authoritative; the Dart mirror is
//! optimistic UI only, so a divergence is a cosmetic bug rather than a consensus
//! one.
//!
//! `state.rs` re-exports `Rank` and `COMPOSITION`. Downstream code should import
//! them from there rather than reaching into this module for types.
//!
//! The caller owns board mutation. This function only says who lives.

/// Result of a rank comparison.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
#[cfg_attr(
    feature = "borsh",
    derive(borsh::BorshDeserialize, borsh::BorshSerialize)
)]
#[cfg_attr(
    feature = "serde",
    derive(serde::Serialize, serde::Deserialize, schemars::JsonSchema)
)]
pub enum Exchange {
    /// Attacker survives and advances into the contested square.
    AttackerWins,
    /// Attacker is removed; defender holds its square.
    DefenderWins,
    /// Both removed; the contested square is left empty (a "split").
    BothEliminated,
}

/// Piece rank. Discriminant order is strength order among officers only.
/// `Flag` and `Spy` sort below `Private` and are handled by special arms.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
#[repr(u8)]
#[cfg_attr(
    feature = "borsh",
    derive(borsh::BorshDeserialize, borsh::BorshSerialize)
)]
#[cfg_attr(feature = "borsh", borsh(use_discriminant = true))]
#[cfg_attr(
    feature = "serde",
    derive(serde::Serialize, serde::Deserialize, schemars::JsonSchema)
)]
pub enum Rank {
    Flag = 0,
    Spy = 1,
    Private = 2,
    Sergeant = 3,
    SecondLieutenant = 4,
    FirstLieutenant = 5,
    Captain = 6,
    Major = 7,
    LieutenantColonel = 8,
    Colonel = 9,
    BrigadierGeneral = 10,  // one star
    MajorGeneral = 11,      // two stars
    LieutenantGeneral = 12, // three stars
    General = 13,           // four stars
    FiveStarGeneral = 14,
}

impl Rank {
    pub const COUNT: usize = 15;

    pub const ALL: [Rank; Self::COUNT] = [
        Rank::Flag,
        Rank::Spy,
        Rank::Private,
        Rank::Sergeant,
        Rank::SecondLieutenant,
        Rank::FirstLieutenant,
        Rank::Captain,
        Rank::Major,
        Rank::LieutenantColonel,
        Rank::Colonel,
        Rank::BrigadierGeneral,
        Rank::MajorGeneral,
        Rank::LieutenantGeneral,
        Rank::General,
        Rank::FiveStarGeneral,
    ];

    /// Inverse of the discriminant. Panics on out-of-range input; callers pass
    /// values that came out of a validated leaf.
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => Rank::Flag,
            1 => Rank::Spy,
            2 => Rank::Private,
            3 => Rank::Sergeant,
            4 => Rank::SecondLieutenant,
            5 => Rank::FirstLieutenant,
            6 => Rank::Captain,
            7 => Rank::Major,
            8 => Rank::LieutenantColonel,
            9 => Rank::Colonel,
            10 => Rank::BrigadierGeneral,
            11 => Rank::MajorGeneral,
            12 => Rank::LieutenantGeneral,
            13 => Rank::General,
            14 => Rank::FiveStarGeneral,
            _ => panic!("rank out of range"),
        }
    }
}

/// Canonical composition per side. Sums to 21; asserted in tests.
pub const COMPOSITION: [(Rank, u8); 15] = [
    (Rank::Flag, 1),
    (Rank::Spy, 2),
    (Rank::Private, 6),
    (Rank::Sergeant, 1),
    (Rank::SecondLieutenant, 1),
    (Rank::FirstLieutenant, 1),
    (Rank::Captain, 1),
    (Rank::Major, 1),
    (Rank::LieutenantColonel, 1),
    (Rank::Colonel, 1),
    (Rank::BrigadierGeneral, 1),
    (Rank::MajorGeneral, 1),
    (Rank::LieutenantGeneral, 1),
    (Rank::General, 1),
    (Rank::FiveStarGeneral, 1),
];

/// Independent 15x15 expectation table, and the source of truth for the Dart
/// generator. Rows are attackers, columns are defenders, both in `Rank::ALL`
/// order.
///
///   `A` = AttackerWins, `D` = DefenderWins, `B` = BothEliminated
///
/// Written as literal strings rather than derived from the match arms so that a
/// bug in `resolve` cannot also corrupt the expectation.
#[rustfmt::skip]
pub const MATRIX: [&str; Rank::COUNT] = [
    //  FLG SPY PVT SGT 2LT 1LT CPT MAJ LTC COL 1*G 2*G 3*G 4*G 5*G
    "ADDDDDDDDDDDDDD", // FLG
    "ABDAAAAAAAAAAAA", // SPY
    "AABDDDDDDDDDDDD", // PVT
    "ADABDDDDDDDDDDD", // SGT
    "ADAABDDDDDDDDDD", // 2LT
    "ADAAABDDDDDDDDD", // 1LT
    "ADAAAABDDDDDDDD", // CPT
    "ADAAAAABDDDDDDD", // MAJ
    "ADAAAAAABDDDDDD", // LTC
    "ADAAAAAAABDDDDD", // COL
    "ADAAAAAAAABDDDD", // 1*G
    "ADAAAAAAAAABDDD", // 2*G
    "ADAAAAAAAAAABDD", // 3*G
    "ADAAAAAAAAAAABD", // 4*G
    "ADAAAAAAAAAAAAB", // 5*G
];

/// Resolve a challenge. Pure. See module docs for arm ordering.
pub fn resolve(attacker: Rank, defender: Rank) -> Exchange {
    use Rank::*;

    match (attacker, defender) {
        // Flag first: it beats nothing, and everything beats it.
        (Flag, Flag) => Exchange::AttackerWins, // challenging Flag prevails
        (Flag, _) => Exchange::DefenderWins,
        (_, Flag) => Exchange::AttackerWins,

        // Spy second: reusable, beats every officer, loses only to Private.
        (Spy, Spy) => Exchange::BothEliminated,
        (Spy, Private) => Exchange::DefenderWins,
        (Spy, _) => Exchange::AttackerWins,

        (Private, Spy) => Exchange::AttackerWins,
        (_, Spy) => Exchange::DefenderWins,

        // Ladder. Private is the lowest officer, so plain ordering holds here.
        (a, d) if (a as u8) > (d as u8) => Exchange::AttackerWins,
        (a, d) if (a as u8) < (d as u8) => Exchange::DefenderWins,
        _ => Exchange::BothEliminated,
    }
}

/// True when the exchange ends the match for the defender's owner.
///
/// The attacker is accepted but unused — a Flag attacking does not end the game,
/// only a Flag being the *defender* does. The parameter is kept so call sites
/// read symmetrically with `resolve`.
pub fn ends_game(_attacker: Rank, defender: Rank) -> bool {
    defender == Rank::Flag
}

#[cfg(test)]
mod tests {
    use super::*;

    fn expected(a: Rank, d: Rank) -> Exchange {
        match MATRIX[a as usize].as_bytes()[d as usize] {
            b'A' => Exchange::AttackerWins,
            b'D' => Exchange::DefenderWins,
            b'B' => Exchange::BothEliminated,
            c => panic!("bad table cell {c}"),
        }
    }

    #[test]
    fn table_is_well_formed() {
        assert_eq!(MATRIX.len(), Rank::COUNT);
        for row in MATRIX {
            assert_eq!(row.len(), Rank::COUNT, "row {row} wrong width");
        }
        assert_eq!(
            COMPOSITION.iter().map(|(_, n)| *n as u32).sum::<u32>(),
            21,
            "composition must total 21"
        );
    }

    #[test]
    fn full_matrix() {
        let mut checked = 0;
        for &a in Rank::ALL.iter() {
            for &d in Rank::ALL.iter() {
                assert_eq!(resolve(a, d), expected(a, d), "{a:?} vs {d:?}");
                checked += 1;
            }
        }
        assert_eq!(checked, Rank::COUNT * Rank::COUNT);
    }

    #[test]
    fn flag_never_wins_a_fight_except_against_a_flag() {
        for &d in Rank::ALL.iter().filter(|r| **r != Rank::Flag) {
            assert_eq!(resolve(Rank::Flag, d), Exchange::DefenderWins);
        }
        assert_eq!(resolve(Rank::Flag, Rank::Flag), Exchange::AttackerWins);
    }

    #[test]
    fn anything_captures_the_flag() {
        for &a in Rank::ALL.iter().filter(|r| **r != Rank::Flag) {
            assert_eq!(resolve(a, Rank::Flag), Exchange::AttackerWins);
            assert!(ends_game(a, Rank::Flag));
        }
    }

    #[test]
    fn spy_is_reusable_and_only_private_kills_it() {
        for &d in Rank::ALL.iter().filter(|r| **r != Rank::Spy) {
            let e = resolve(Rank::Spy, d);
            if d == Rank::Private {
                assert_eq!(e, Exchange::DefenderWins, "private must kill the spy");
            } else {
                assert_eq!(e, Exchange::AttackerWins, "spy must survive {d:?}");
            }
        }
        assert_eq!(resolve(Rank::Spy, Rank::Spy), Exchange::BothEliminated);
        assert_eq!(resolve(Rank::Private, Rank::Spy), Exchange::AttackerWins);
    }

    #[test]
    fn equal_ranks_split() {
        for &r in Rank::ALL.iter().filter(|r| **r != Rank::Flag) {
            assert_eq!(resolve(r, r), Exchange::BothEliminated, "{r:?} vs itself");
        }
    }

    #[test]
    fn private_loses_to_every_officer() {
        for &d in Rank::ALL
            .iter()
            .filter(|r| !matches!(**r, Rank::Private | Rank::Spy | Rank::Flag))
        {
            assert_eq!(resolve(Rank::Private, d), Exchange::DefenderWins);
        }
    }

    #[test]
    fn game_ends_only_on_a_defending_flag() {
        assert!(!ends_game(Rank::FiveStarGeneral, Rank::Private));
        assert!(!ends_game(Rank::Flag, Rank::Private));
        assert!(ends_game(Rank::Private, Rank::Flag));
        assert!(ends_game(Rank::Flag, Rank::Flag));
    }

    #[test]
    fn from_u8_round_trips() {
        for &r in Rank::ALL.iter() {
            assert_eq!(Rank::from_u8(r as u8), r);
        }
    }
}

#!/usr/bin/env bash
# Extract MATRIX from arbiter.rs and write client/lib/arbiter.g.dart.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/contracts/engkwentro/src/arbiter.rs"
OUT="$ROOT/client/lib/arbiter.g.dart"
python3 - "$SRC" "$OUT" <<'PY'
import pathlib, re, sys
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = src.read_text()
block = re.search(r"pub const MATRIX: \[&str; Rank::COUNT\] = \[(.*?)\];", text, re.S)
if not block:
    raise SystemExit("MATRIX not found")
rows = re.findall(r'"([ADB]{15})"', block.group(1))
if len(rows) != 15:
    raise SystemExit(f"expected 15 rows, got {len(rows)}")
body = "\n".join(f"  '{r}'," for r in rows)
out.write_text(f"""// Generated from contracts/engkwentro/src/arbiter.rs MATRIX.
// Do not edit by hand. Run scripts/gen_arbiter_dart.sh

/// Piece type. Discriminant matches `Rank` in `arbiter.rs`.
enum Rank {{
  flag,
  spy,
  private,
  sergeant,
  secondLieutenant,
  firstLieutenant,
  captain,
  major,
  lieutenantColonel,
  colonel,
  brigadierGeneral,
  majorGeneral,
  lieutenantGeneral,
  general,
  fiveStarGeneral,
}}

/// Fight outcome. Wire names are `AttackerWins` / `DefenderWins` / `BothEliminated`.
enum Exchange {{ attackerWins, defenderWins, bothEliminated }}

/// Short labels painted on a square when the viewer owns that piece.
const rankNames = [
  'FLG', 'SPY', 'PVT', 'SGT', '2LT', '1LT', 'CPT', 'MAJ', 'LTC', 'COL',
  '1*G', '2*G', '3*G', '4*G', '5*G',
];

/// Canonical 21-piece roster. `submit_setup` checks this on the flip.
const composition = <Rank, int>{{
  Rank.flag: 1,
  Rank.spy: 2,
  Rank.private: 6,
  Rank.sergeant: 1,
  Rank.secondLieutenant: 1,
  Rank.firstLieutenant: 1,
  Rank.captain: 1,
  Rank.major: 1,
  Rank.lieutenantColonel: 1,
  Rank.colonel: 1,
  Rank.brigadierGeneral: 1,
  Rank.majorGeneral: 1,
  Rank.lieutenantGeneral: 1,
  Rank.general: 1,
  Rank.fiveStarGeneral: 1,
}};

/// Source of truth copied from `MATRIX` in arbiter.rs. Rows = attacker.
const matrix = [
{body}
];

/// Looks up [attacker] vs [defender] in [matrix].
Exchange resolve(Rank attacker, Rank defender) {{
  switch (matrix[attacker.index][defender.index]) {{
    case 'A':
      return Exchange.attackerWins;
    case 'D':
      return Exchange.defenderWins;
    case 'B':
      return Exchange.bothEliminated;
    default:
      throw StateError('bad matrix cell');
  }}
}}

/// Whether capturing [defender] ends the match (only the Flag).
bool endsGame(Rank defender) => defender == Rank.flag;
""")
print(f"wrote {out}")
PY

import 'arbiter.g.dart';

/// Which side of the board. A sits on ranks 0–2, B on 5–7.
enum Side { a, b }

/// One piece on the local board. [id] is the roster index 0–20.
class Piece {
  /// Places [rank] for [side] at roster slot [id].
  Piece(this.side, this.rank, this.id);

  /// Owner.
  final Side side;

  /// Hidden rank. Painted only when [MatchGame.visible] is true.
  final Rank rank;

  /// Stable roster index, independent of square.
  final int id;
}

/// Local pass-and-play engine. Same `MATRIX` as the contract.
class MatchGame {
  /// Default 21+21 layout on the three home rows each.
  MatchGame.standard() {
    _placeDefault(Side.a);
    _placeDefault(Side.b);
    toMove = Side.a;
  }

  /// 72 squares, file + rank×9. `null` is empty.
  final List<Piece?> board = List<Piece?>.filled(72, null);

  /// Side that must move.
  Side toMove = Side.a;

  /// Whose ranks to paint. `null` shows both (debug).
  Side? viewer;

  /// Terminal sentence, or `null` while the match is live.
  String? result;

  /// Last-move note for the status line.
  String log = 'Place or start.';

  /// Selected square, or `null`.
  int? selected;

  /// True after a Flag steps onto the enemy home row.
  bool breakthrough = false;

  /// Who just arrived, when [breakthrough] is set.
  Side? breakthroughBy;

  /// Square the Flag arrived on.
  int? breakthroughAt;

  /// A's three home ranks (board_rank 0–2).
  static const homeA = [0, 1, 2];

  /// B's three home ranks (board_rank 5–7).
  static const homeB = [5, 6, 7];

  /// Wire square from 0-based [file] and [rank].
  static int sq(int file, int rank) => file + rank * 9;

  /// File 0–8 of square [s].
  static int fileOf(int s) => s % 9;

  /// Board rank 0–7 of square [s].
  static int rankOf(int s) => s ~/ 9;

  /// The opponent of [s].
  Side other(Side s) => s == Side.a ? Side.b : Side.a;

  /// Drops the canonical 21-piece roster onto [side]'s home rows.
  void _placeDefault(Side side) {
    final ranks = <Rank>[
      Rank.private,
      Rank.private,
      Rank.private,
      Rank.private,
      Rank.private,
      Rank.private,
      Rank.sergeant,
      Rank.secondLieutenant,
      Rank.firstLieutenant,
      Rank.captain,
      Rank.major,
      Rank.lieutenantColonel,
      Rank.colonel,
      Rank.brigadierGeneral,
      Rank.majorGeneral,
      Rank.lieutenantGeneral,
      Rank.general,
      Rank.fiveStarGeneral,
      Rank.spy,
      Rank.spy,
      Rank.flag,
    ];
    final front = side == Side.a ? 0 : 7;
    final mid = side == Side.a ? 1 : 6;
    final back = side == Side.a ? 2 : 5;
    var i = 0;
    for (final r in [front, mid]) {
      for (var f = 0; f < 9; f++) {
        board[sq(f, r)] = Piece(side, ranks[i], i);
        i++;
      }
    }
    for (var f = 0; f < 3; f++) {
      board[sq(f, back)] = Piece(side, ranks[i], i);
      i++;
    }
  }

  /// Whether [s] is on the enemy home rank for [side].
  bool onEnemyHome(Side side, int s) => rankOf(s) == (side == Side.a ? 7 : 0);

  /// Orthogonal one-step, on the board, not a stay.
  ///
  /// Shared with [NetSession] so net play can reject illegal taps before a tx.
  static bool isOrthogonalStep(int from, int to) {
    if (from == to || from < 0 || to < 0 || from > 71 || to > 71) return false;
    final df = (fileOf(from) - fileOf(to)).abs();
    final dr = (rankOf(from) - rankOf(to)).abs();
    return (df == 1 && dr == 0) || (df == 0 && dr == 1);
  }

  /// Orthogonal one-step, on the board, not a stay.
  bool isStep(int from, int to) => isOrthogonalStep(from, to);

  /// [side] may step from [from] to [to] onto empty or enemy.
  bool legal(Side side, int from, int to) {
    final p = board[from];
    if (p == null || p.side != side || !isStep(from, to)) return false;
    final dest = board[to];
    return dest == null || dest.side != side;
  }

  /// Whether [side] has at least one legal destination.
  bool hasMove(Side side) {
    for (var from = 0; from < 72; from++) {
      final p = board[from];
      if (p == null || p.side != side) continue;
      for (final d in [-1, 1, -9, 9]) {
        final to = from + d;
        if (d.abs() == 1 && rankOf(from) != rankOf(to)) continue;
        if (legal(side, from, to)) return true;
      }
    }
    return false;
  }

  /// Plays [from]→[to] for [toMove]. Returns a result string if the match ended.
  String? play(int from, int to) {
    if (result != null) return result;
    if (!legal(toMove, from, to)) {
      log = 'Illegal move.';
      return null;
    }
    if (breakthrough) {
      if (to == breakthroughAt && board[to]?.side == breakthroughBy) {
        return _challenge(from, to);
      }
      result = '${_name(breakthroughBy!)} wins — flag breakthrough.';
      log = result!;
      return result;
    }
    if (board[to] != null) return _challenge(from, to);
    board[to] = board[from];
    board[from] = null;
    if (onEnemyHome(toMove, to) && board[to]!.rank == Rank.flag) {
      breakthrough = true;
      breakthroughBy = toMove;
      breakthroughAt = to;
      toMove = other(toMove);
      log = 'Flag on the home row. ${_name(toMove)} must challenge it or lose.';
      return null;
    }
    return _finish();
  }

  /// Resolves a challenge on [to] using [resolve], then [_finish].
  String? _challenge(int from, int to) {
    final atk = board[from]!;
    final def = board[to]!;
    final exchange = resolve(atk.rank, def.rank);
    final flag = endsGame(def.rank);
    switch (exchange) {
      case Exchange.attackerWins:
        board[to] = atk;
        board[from] = null;
        log =
            '${rankNames[atk.rank.index]} takes ${rankNames[def.rank.index]}.';
      case Exchange.defenderWins:
        board[from] = null;
        log =
            '${rankNames[def.rank.index]} holds against ${rankNames[atk.rank.index]}.';
      case Exchange.bothEliminated:
        board[from] = null;
        board[to] = null;
        log =
            '${rankNames[atk.rank.index]} and ${rankNames[def.rank.index]} split.';
    }
    if (flag) {
      result = '${_name(atk.side)} wins — flag captured.';
      log = result!;
      return result;
    }
    breakthrough = false;
    return _finish();
  }

  /// Immobilisation check, then pass the turn.
  String? _finish() {
    final incoming = other(toMove);
    if (!hasMove(incoming)) {
      result = '${_name(toMove)} wins — opponent immobilised.';
      log = result!;
      return result;
    }
    toMove = incoming;
    selected = null;
    return null;
  }

  /// Player-facing name of [s].
  String _name(Side s) => s == Side.a ? 'Player A' : 'Player B';

  /// Whether the piece on [s] should show its rank to [viewer].
  bool visible(int s) {
    final p = board[s];
    if (p == null) return false;
    if (viewer == null) return true;
    return p.side == viewer;
  }

  /// Ends the match as a win for the opponent of [side].
  void resign(Side side) {
    result = '${_name(other(side))} wins — resignation.';
    log = result!;
  }
}

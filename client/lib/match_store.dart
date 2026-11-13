import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'arbiter.g.dart';

/// Open-challenge placeholder on the contract until someone joins by key.
const openOpponentAccount = 'open.engkwentro.testnet';

/// Local sealed-army + match binding for disconnect / rejoin.
class MatchLocalState {
  /// Snapshot for [accountId] on [matchId].
  MatchLocalState({
    required this.matchId,
    required this.joinKey,
    required this.accountId,
    required this.sideA,
    required this.rosterReady,
    this.ranks = const [],
    this.squares = const [],
    this.salts = const [],
  });

  /// Sequential on-chain match id.
  final int matchId;

  /// Shareable 12-character key (may be empty if only the id was known).
  final String joinKey;

  /// NEAR account that owns this local copy.
  final String accountId;

  /// True when this account is the creator (side A).
  final bool sideA;

  /// True after a successful `commit_setup` on this device.
  final bool rosterReady;

  /// 21 ranks when [rosterReady].
  final List<Rank> ranks;

  /// 21 `(file, board_rank)` homes when [rosterReady].
  final List<(int, int)> squares;

  /// 21 salts when [rosterReady].
  final List<Uint8List> salts;

  /// JSON for [SharedPreferences].
  Map<String, dynamic> toJson() => {
        'matchId': matchId,
        'joinKey': joinKey,
        'accountId': accountId,
        'sideA': sideA,
        'rosterReady': rosterReady,
        'ranks': [for (final r in ranks) r.index],
        'squares': [
          for (final s in squares) [s.$1, s.$2],
        ],
        'salts': [
          for (final salt in salts)
            salt.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        ],
      };

  /// Parses [toJson] output.
  factory MatchLocalState.fromJson(Map<String, dynamic> json) {
    final rankIdx = (json['ranks'] as List?) ?? const [];
    final squareRaw = (json['squares'] as List?) ?? const [];
    final saltHex = (json['salts'] as List?) ?? const [];
    return MatchLocalState(
      matchId: json['matchId'] as int,
      joinKey: (json['joinKey'] as String?) ?? '',
      accountId: json['accountId'] as String,
      sideA: json['sideA'] as bool? ?? true,
      rosterReady: json['rosterReady'] as bool? ?? false,
      ranks: [
        for (final i in rankIdx) Rank.values[i as int],
      ],
      squares: [
        for (final s in squareRaw)
          ((s as List)[0] as int, s[1] as int),
      ],
      salts: [
        for (final h in saltHex) _hexToBytes(h as String),
      ],
    );
  }
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Persists the latest match per account so either side can rejoin.
class MatchStore {
  static String _key(String accountId) => 'engkwentro.match.$accountId';

  /// Writes [state] for [state.accountId], replacing any prior match.
  static Future<void> save(MatchLocalState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(state.accountId), jsonEncode(state.toJson()));
  }

  /// Loads the saved match for [accountId], or null.
  static Future<MatchLocalState?> load(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(accountId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return MatchLocalState.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Drops the saved match for [accountId].
  static Future<void> clear(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(accountId));
  }
}

// Intentional AUDIT console line for local demos.
// ignore_for_file: avoid_print
import 'dart:convert';

/// One successful NEAR call, kept on the device.
///
/// Printed as `AUDIT {…}`. Nothing here is written on chain — cheaper than
/// extra event bytes, and the contract cannot know the tx hash.
class AuditEntry {
  /// Builds a row from a finished `broadcast_tx_commit` (or polled `tx`).
  AuditEntry({
    required this.txHash,
    required this.method,
    required this.account,
    required this.matchId,
    required this.tokensBurnt,
    required this.tgas,
  });

  /// Base58 tx hash, the Nearblocks path segment.
  final String txHash;

  /// Contract method that was called.
  final String method;

  /// Signer / predecessor.
  final String account;

  /// Match id from the call args, or from a `create_match` return.
  final int? matchId;

  /// Sum of `tokens_burnt` on the transaction and its receipts, as yocto.
  final String tokensBurnt;

  /// Sum of `gas_burnt` on those outcomes, in TGas.
  final double tgas;

  /// JSON object matching the `AUDIT` log line.
  Map<String, dynamic> toJson() => {
    'tx_hash': txHash,
    'method': method,
    'account': account,
    'match_id': matchId,
    'tokens_burnt': tokensBurnt,
    'tgas': tgas,
  };
}

/// In-memory list of [AuditEntry]s for this process.
class AuditLog {
  /// Oldest first.
  final List<AuditEntry> entries = [];

  /// Appends [e] and prints `AUDIT` plus its JSON.
  void add(AuditEntry e) {
    entries.add(e);
    print('AUDIT ${jsonEncode(e.toJson())}');
  }

  /// Number of recorded calls.
  int get count => entries.length;

  /// Most recent entry, or `null` if the log is empty.
  AuditEntry? get last => entries.isEmpty ? null : entries.last;
}

/// Pulls `match_id` from call args, else from a numeric `decoded` return.
int? matchIdFromArgs(Object args, Map<String, dynamic> result) {
  if (args is Map && args['match_id'] != null) {
    final v = args['match_id'];
    if (v is int) return v;
    return int.tryParse(v.toString());
  }
  final decoded = result['decoded'];
  if (decoded is int) return decoded;
  if (decoded is List && decoded.isNotEmpty) {
    final v = decoded[0];
    if (v is int) return v;
    return int.tryParse(v.toString());
  }
  return null;
}

/// Sums `tokens_burnt` / `gas_burnt` across the tx and receipt outcomes.
///
/// Writes `tokens_burnt` and `tgas` back onto [tx] for the caller.
String tokensBurntFromTx(Map<String, dynamic> tx) {
  var burnt = BigInt.zero;
  var gas = BigInt.zero;

  /// Accumulates one outcome's burnt tokens and gas.
  void take(Map<String, dynamic>? outcome) {
    if (outcome == null) return;
    burnt += BigInt.parse('${outcome['tokens_burnt'] ?? 0}');
    gas += BigInt.parse('${outcome['gas_burnt'] ?? 0}');
  }

  final to = tx['transaction_outcome'];
  if (to is Map) {
    take(Map<String, dynamic>.from((to['outcome'] as Map?) ?? const {}));
  }
  final receipts = tx['receipts_outcome'];
  if (receipts is List) {
    for (final r in receipts) {
      if (r is Map) {
        take(Map<String, dynamic>.from((r['outcome'] as Map?) ?? const {}));
      }
    }
  }
  tx['tokens_burnt'] = burnt.toString();
  tx['tgas'] = gas.toDouble() / 1e12;
  return burnt.toString();
}

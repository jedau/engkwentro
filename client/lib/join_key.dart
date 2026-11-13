/// Crockford-style alphabet: no `0 O I 1`. Same as `contracts/.../join.rs`.
/// User-facing match key; sequential `match_id` stays the audit id.
const joinAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Length of a stored key, before grouping dashes.
const joinKeyLen = 12;

/// Uppercase and drop dashes / spaces so typed keys match the chain.
String normalizeJoinKey(String raw) {
  return raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
}

/// Groups 12 characters as `XXXX-XXXX-XXXX` for the share line.
String formatJoinKey(String raw) {
  final n = normalizeJoinKey(raw);
  if (n.length != joinKeyLen) return n;
  return '${n.substring(0, 4)}-${n.substring(4, 8)}-${n.substring(8, 12)}';
}

/// Whether [raw] is a complete key after normalize.
bool isJoinKey(String raw) => normalizeJoinKey(raw).length == joinKeyLen;

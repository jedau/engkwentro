import 'dart:convert';

import 'package:http/http.dart' as http;

/// Keyed blob store for 1-of-15 OT. Not an oracle.
///
/// Keys are `{recv,send,open}-{from}-{to}` under a match id. Local default
/// is `scripts/mailbox_local.mjs` on `:8787`.
///
/// One keep-alive connection, and a deadline on every call: a mailbox that
/// stops answering fails the step in seconds instead of hanging the match.
class Mailbox {
  /// [baseUrl] has no trailing slash, e.g. `http://127.0.0.1:8787`.
  Mailbox(this.baseUrl);

  /// Origin of the mailbox process.
  final String baseUrl;

  final http.Client _http = http.Client();

  static const _timeout = Duration(seconds: 5);

  /// Overwrites the blob at [key] for [matchId].
  Future<void> put(String matchId, String key, String blob) async {
    final res = await _http
        .post(
          Uri.parse('$baseUrl/mailbox'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'match_id': matchId, 'key': key, 'blob': blob}),
        )
        .timeout(_timeout);
    if (res.statusCode >= 400) {
      throw StateError('mailbox put ${res.statusCode}: ${res.body}');
    }
  }

  /// Returns the blob at [key], or `null` if the slot is empty.
  ///
  /// Does not wait. The match driver retries.
  Future<String?> get(String matchId, String key) async {
    final res = await _http
        .get(Uri.parse('$baseUrl/mailbox?match_id=$matchId&key=$key'))
        .timeout(_timeout);
    if (res.statusCode >= 400) {
      throw StateError('mailbox get ${res.statusCode}: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['blob'] as String?;
  }

  /// Polls [get] until the blob is non-empty or [tries] is exhausted.
  Future<String?> wait(String matchId, String key, {int tries = 40}) async {
    for (var i = 0; i < tries; i++) {
      final blob = await get(matchId, key);
      if (blob != null && blob.isNotEmpty) return blob;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }
}

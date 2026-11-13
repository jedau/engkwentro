import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'arbiter.g.dart';

/// `sha256(rank_id || salt)` — same bytes as `setup::piece_commitment`.
///
/// [salt] must be 32 bytes. The digest is 32 bytes, stored on the square.
List<int> pieceCommitment(Rank rank, List<int> salt) {
  if (salt.length != 32) {
    throw ArgumentError('salt must be 32 bytes');
  }
  final buf = Uint8List(33);
  buf[0] = rank.index;
  buf.setRange(1, 33, salt);
  return sha256.convert(buf).bytes;
}

/// Hex encoding of [pieceCommitment] for logs and tests.
String commitmentHex(Rank rank, List<int> salt) =>
    pieceCommitment(rank, salt).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Home squares for the default army, in the same order as [defaultRoster].
///
/// Bob's narrow forward row uses wire files 6–8 so that, under a 180° display
/// flip, it sits on his visual columns 1–3 and Alice sees it on 7–8–9.
List<(int, int)> homeSquares(bool sideA) {
  final out = <(int, int)>[];
  for (final boardRank in sideA ? [0, 1, 2] : [5, 6, 7]) {
    final narrow =
        (sideA && boardRank == 2) || (!sideA && boardRank == 5);
    if (narrow) {
      final files = sideA ? [0, 1, 2] : [6, 7, 8];
      for (final file in files) {
        out.add((file, boardRank));
      }
    } else {
      for (var file = 0; file < 9; file++) {
        out.add((file, boardRank));
      }
    }
  }
  return out;
}

/// Default 21-piece roster in the same order as the sandbox army.
List<Rank> defaultRoster() {
  final out = <Rank>[];
  composition.forEach((rank, n) {
    for (var i = 0; i < n; i++) {
      out.add(rank);
    }
  });
  return out;
}

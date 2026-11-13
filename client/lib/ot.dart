import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'arbiter.g.dart';

/// 1-out-of-15 table lookup for a fight.
///
/// Honest path: same as [resolve]. A hostile attacker can seal a fake row
/// (Alice’s Five-star); the flip audits that later.
Exchange localExchange(Rank attacker, Rank defender) => resolve(attacker, defender);

/// Honest sender messages: `messages[i] = MATRIX[attacker][i]`.
List<Exchange> otSenderRow(Rank attacker) {
  return Rank.values.map((d) => resolve(attacker, d)).toList();
}

/// Honest receiver: pick column [defender].
Exchange otReceive(List<Exchange> row, Rank defender) => row[defender.index];

/// NEAR JSON enum names, in `Rank` discriminant order.
const rankWire = [
  'Flag',
  'Spy',
  'Private',
  'Sergeant',
  'SecondLieutenant',
  'FirstLieutenant',
  'Captain',
  'Major',
  'LieutenantColonel',
  'Colonel',
  'BrigadierGeneral',
  'MajorGeneral',
  'LieutenantGeneral',
  'General',
  'FiveStarGeneral',
];

/// Serialises [e] to the contract's `Exchange` JSON string.
String exchangeWire(Exchange e) {
  switch (e) {
    case Exchange.attackerWins:
      return 'AttackerWins';
    case Exchange.defenderWins:
      return 'DefenderWins';
    case Exchange.bothEliminated:
      return 'BothEliminated';
  }
}

/// Parses a contract or Dart-style [Exchange] name.
Exchange exchangeFromWire(String s) {
  switch (s) {
    case 'AttackerWins':
    case 'attackerWins':
      return Exchange.attackerWins;
    case 'DefenderWins':
    case 'defenderWins':
      return Exchange.defenderWins;
    case 'BothEliminated':
    case 'bothEliminated':
      return Exchange.bothEliminated;
    default:
      throw FormatException('unknown exchange $s');
  }
}

final _x25519 = X25519();
final _box = Chacha20.poly1305Aead();

/// Defender's 15 published public keys plus the one real secret.
class OtOffer {
  /// [secret] is non-null only for the defender's true rank column.
  OtOffer(this.publicKeys, this.secret);

  /// 15 × 32-byte X25519 public keys (14 of them random bytes).
  final List<Uint8List> publicKeys;

  /// SK for the real column, or `null` if this object is attacker-side.
  final SimpleKeyPair? secret;
}

/// Defender publishes 15 public keys and keeps only the SK for [defender].
Future<OtOffer> otOffer(Rank defender) async {
  final pks = <Uint8List>[];
  SimpleKeyPair? secret;
  final rnd = Random.secure();
  for (var i = 0; i < Rank.values.length; i++) {
    if (i == defender.index) {
      secret = await _x25519.newKeyPair();
      final pub = await secret.extractPublicKey();
      pks.add(Uint8List.fromList(pub.bytes));
    } else {
      pks.add(Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256))));
    }
  }
  return OtOffer(pks, secret);
}

/// Attacker encrypts one MATRIX row to the 15 published keys.
///
/// Each cell is `base64(eph_pk || nonce || ciphertext || mac)`.
Future<String> otSealRow(Rank attacker, List<Uint8List> publicKeys) async {
  final cells = <String>[];
  for (var i = 0; i < publicKeys.length; i++) {
    final msg = utf8.encode(exchangeWire(otSenderRow(attacker)[i]));
    final eph = await _x25519.newKeyPair();
    final remote = SimplePublicKey(publicKeys[i], type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(keyPair: eph, remotePublicKey: remote);
    final nonce = _box.newNonce();
    final boxed = await _box.encrypt(msg, secretKey: shared, nonce: nonce);
    final ephPub = await eph.extractPublicKey();
    cells.add(
      base64.encode([
        ...ephPub.bytes,
        ...boxed.nonce,
        ...boxed.cipherText,
        ...boxed.mac.bytes,
      ]),
    );
  }
  return jsonEncode(cells);
}

/// Defender opens only their column.
Future<Exchange> otOpenCell(String sealed, Rank defender, SimpleKeyPair secret) async {
  final cells = (jsonDecode(sealed) as List).cast<String>();
  final raw = base64.decode(cells[defender.index]);
  final ephPub = SimplePublicKey(raw.sublist(0, 32), type: KeyPairType.x25519);
  final nonce = raw.sublist(32, 44);
  final mac = Mac(raw.sublist(raw.length - 16));
  final cipher = raw.sublist(44, raw.length - 16);
  final shared = await _x25519.sharedSecretKey(keyPair: secret, remotePublicKey: ephPub);
  final opened = await _box.decrypt(
    SecretBox(cipher, nonce: nonce, mac: mac),
    secretKey: shared,
  );
  return exchangeFromWire(utf8.decode(opened));
}

/// JSON array of base64 public keys for the mailbox.
String encodeOffer(List<Uint8List> publicKeys) =>
    jsonEncode(publicKeys.map(base64.encode).toList());

/// Inverse of [encodeOffer].
List<Uint8List> decodeOffer(String blob) => (jsonDecode(blob) as List)
    .map((e) => Uint8List.fromList(base64.decode(e as String)))
    .toList();

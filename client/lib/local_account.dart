import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:near_dart/near_dart.dart';

/// Testnet faucet that creates and funds a named account.
const defaultFaucetUrl = 'https://helper.testnet.near.org/account';

/// Secure-storage keys for the in-app play account.
abstract final class LocalAccountKeys {
  /// Named `.testnet` account id.
  static const accountId = 'engkwentro.local.accountId';

  /// `ed25519:` secret key for local signing.
  static const privateKey = 'engkwentro.local.privateKey';
}

/// Result of creating or restoring an in-app play account.
class LocalAccount {
  /// [accountId] is a named testnet id; [privateKey] is `ed25519:…`.
  const LocalAccount({required this.accountId, required this.privateKey});

  /// NEAR account id (e.g. `player-abc123.testnet`).
  final String accountId;

  /// Extended secret key used by [NearClient].
  final String privateKey;
}

/// Generates a key, funds a named testnet account via the helper faucet,
/// and persists credentials in [FlutterSecureStorage].
class LocalAccountFactory {
  /// [client] is injectable for tests; [storage] defaults to encrypted prefs.
  LocalAccountFactory({
    http.Client? client,
    FlutterSecureStorage? storage,
    this.faucetUrl = defaultFaucetUrl,
  }) : _client = client ?? http.Client(),
       _storage = storage ?? const FlutterSecureStorage();

  final http.Client _client;
  final FlutterSecureStorage _storage;

  /// POST target for named testnet account creation.
  final String faucetUrl;

  /// Reads a previously saved play account, or null.
  Future<LocalAccount?> restore() async {
    final accountId = await _storage.read(key: LocalAccountKeys.accountId);
    final privateKey = await _storage.read(key: LocalAccountKeys.privateKey);
    if (accountId == null ||
        accountId.isEmpty ||
        privateKey == null ||
        privateKey.isEmpty) {
      return null;
    }
    return LocalAccount(accountId: accountId, privateKey: privateKey);
  }

  /// Deletes the stored play account credentials.
  Future<void> clear() async {
    await _storage.delete(key: LocalAccountKeys.accountId);
    await _storage.delete(key: LocalAccountKeys.privateKey);
  }

  /// Creates a funded testnet account and stores the key on device.
  ///
  /// [preferredName] may be `alice` or `alice.testnet`. Empty/null yields
  /// `player-<rand>.testnet`. Retries on name collision.
  Future<LocalAccount> create({String? preferredName}) async {
    final keyPair = await KeyPairEd25519.generate();
    final publicKey = keyPair.publicKey.value;
    final privateKey = keyPair.toString();

    Object? lastError;
    for (var attempt = 0; attempt < 5; attempt++) {
      final accountId = _resolveName(preferredName, attempt: attempt);
      try {
        await _faucetCreate(accountId: accountId, publicKey: publicKey);
        final account = LocalAccount(
          accountId: accountId,
          privateKey: privateKey,
        );
        await _persist(account);
        return account;
      } catch (e) {
        lastError = e;
        // Only retry with a fresh auto name when the preferred name collides.
        if (preferredName != null &&
            preferredName.trim().isNotEmpty &&
            attempt == 0) {
          preferredName = null;
        }
      }
    }
    throw StateError('Could not create testnet account: $lastError');
  }

  Future<void> _persist(LocalAccount account) async {
    await _storage.write(
      key: LocalAccountKeys.accountId,
      value: account.accountId,
    );
    await _storage.write(
      key: LocalAccountKeys.privateKey,
      value: account.privateKey,
    );
  }

  Future<void> _faucetCreate({
    required String accountId,
    required String publicKey,
  }) async {
    final res = await _client.post(
      Uri.parse(faucetUrl),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'newAccountId': accountId,
        'newAccountPublicKey': publicKey,
      }),
    );
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    throw StateError(
      'Faucet ${res.statusCode}: ${res.body.isEmpty ? '(empty)' : res.body}',
    );
  }

  /// Normalizes a preferred label into a unique `.testnet` id.
  static String _resolveName(String? preferred, {required int attempt}) {
    final raw = preferred?.trim() ?? '';
    if (raw.isEmpty) {
      return 'player-${_randToken()}${attempt == 0 ? '' : '-$attempt'}.testnet';
    }
    var base = raw.toLowerCase();
    if (base.endsWith('.testnet')) {
      base = base.substring(0, base.length - '.testnet'.length);
    }
    base = base.replaceAll(RegExp(r'[^a-z0-9_-]'), '');
    if (base.isEmpty) {
      return 'player-${_randToken()}.testnet';
    }
    if (attempt == 0) return '$base.testnet';
    return '$base-${_randToken()}.testnet';
  }

  static String _randToken() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(
      8,
      (_) => alphabet[rng.nextInt(alphabet.length)],
    ).join();
  }
}

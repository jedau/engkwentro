import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bs58/bs58.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'audit.dart';

/// Minimal NEAR JSON-RPC client. Player account is the predecessor.
///
/// FastNEAR first, official testnet RPC last. A 429 or a dead socket rotates
/// the endpoint for [_fallbackFor], then the primary is tried again — the
/// official endpoint answers ~10x slower, so it must never become sticky.
///
/// One keep-alive connection is reused for every call, and every call has a
/// deadline: a stalled socket fails in seconds instead of hanging the match.
/// `broadcast_tx_commit` TIMEOUT is recovered by polling `tx`.
class NearClient {
  /// [rpcUrl] is tried first unless it is the rate-limited official endpoint.
  NearClient({
    required this.rpcUrl,
    required this.accountId,
    required this.privateKey,
    required this.contractId,
  }) : _endpoints = _rpcList(rpcUrl);

  /// Preferred RPC, may be skipped if it is `rpc.testnet.near.org`.
  final String rpcUrl;

  /// Signer. Becomes `predecessor_id` on the contract.
  final String accountId;

  /// `ed25519:` plus base58, 32-byte seed or 64-byte seed||pub.
  final String privateKey;

  /// Match contract, e.g. `play.engkwentro.testnet`.
  final String contractId;

  final List<String> _endpoints;

  Uint8List? _seed;
  Uint8List? _pub;

  /// `ed25519:` plus base58 of the public key, filled by [ready].
  String publicKey = '';

  int? _nonce;
  int _rpcIndex = 0;
  DateTime? _rotatedAt;
  http.Client _http = http.Client();

  /// Recent final block hash, reused briefly so a move costs one round trip.
  Uint8List? _blockHash;
  DateTime? _blockHashAt;

  /// Deadline for views and other reads.
  static const _readTimeout = Duration(seconds: 4);

  /// Deadline for `broadcast_tx_commit` (the node waits for execution).
  static const _commitTimeout = Duration(seconds: 10);

  /// How long a fallback endpoint is used before the primary is retried.
  static const _fallbackFor = Duration(seconds: 20);

  /// How long a fetched block hash is reused. Kept far below the shortest
  /// transaction validity window so a cached hash can never expire a tx.
  static const _blockHashFor = Duration(seconds: 10);

  /// Local receipt log for this process.
  final AuditLog audit = AuditLog();

  /// Derives [_seed], [_pub], and [publicKey] from [privateKey]. Idempotent.
  Future<void> ready() async {
    if (_seed != null) return;
    final raw = _decodeKey(privateKey);
    if (raw.length == 64) {
      _seed = Uint8List.fromList(raw.sublist(0, 32));
      _pub = Uint8List.fromList(raw.sublist(32));
    } else if (raw.length == 32) {
      _seed = raw;
      final pair = await Ed25519().newKeyPairFromSeed(_seed!);
      _pub = Uint8List.fromList(await pair.extractPublicKey().then((p) => p.bytes));
    } else {
      throw ArgumentError('NEAR key must be 32 or 64 bytes');
    }
    publicKey = 'ed25519:${base58.encode(_pub!)}';
  }

  /// `call_function` view. [args] is JSON-encoded then base64.
  Future<dynamic> view(String method, [Object args = const {}]) async {
    final payload = base64.encode(utf8.encode(jsonEncode(args)));
    final res = await _rpc('query', {
      'request_type': 'call_function',
      'finality': 'optimistic',
      'account_id': contractId,
      'method_name': method,
      'args_base64': payload,
    });
    final bytes = List<int>.from(res['result'] as List);
    if (bytes.isEmpty) return null;
    return jsonDecode(utf8.decode(bytes));
  }

  /// Signs and submits a FunctionCall. Records an [AuditEntry] on success.
  ///
  /// Empty NEP-413 fields on `SignedMove` are valid: the predecessor is the
  /// player. On TIMEOUT, polls `tx` by hash instead of resubmitting.
  Future<Map<String, dynamic>> call(
    String method,
    Object args, {
    String depositYocto = '0',
    int gas = 100000000000000,
  }) async {
    await ready();
    final nonce = await _nextNonce();
    final blockHash = await _recentBlockHash();
    final tx = _transaction(
      nonce: nonce,
      blockHash: blockHash,
      method: method,
      args: utf8.encode(jsonEncode(args)),
      gas: gas,
      deposit: BigInt.parse(depositYocto),
    );
    final hash = sha256.convert(tx).bytes;
    final txHash = base58.encode(Uint8List.fromList(hash));
    final pair = await Ed25519().newKeyPairFromSeed(_seed!);
    final sig = await Ed25519().sign(hash, keyPair: pair);
    final signed = BytesBuilder()
      ..add(tx)
      ..addByte(0)
      ..add(sig.bytes);
    final signedB64 = base64.encode(signed.toBytes());
    Map<String, dynamic> map;
    try {
      final res = await _rpc(
        'broadcast_tx_commit',
        [signedB64],
        timeout: _commitTimeout,
      );
      map = Map<String, dynamic>.from(res as Map);
    } catch (e) {
      // The node gave up waiting, or our socket did. The transaction may
      // still have landed: ask for it by hash rather than resubmitting.
      if (e is! TimeoutException && !e.toString().contains('TIMEOUT')) {
        _nonce = null;
        rethrow;
      }
      _nonce = null;
      map = await _awaitTx(txHash);
    }
    map['tx_hash'] = txHash;
    final status = map['status'];
    if (status is Map && status['Failure'] != null) {
      final fail = status['Failure'].toString();
      if (fail.contains('InvalidNonce') || fail.contains('invalid nonce')) {
        _nonce = null;
      }
      throw StateError('tx failed: ${status['Failure']}');
    }
    if (status is Map && status['SuccessValue'] is String) {
      final raw = status['SuccessValue'] as String;
      if (raw.isNotEmpty) {
        try {
          map['decoded'] = jsonDecode(utf8.decode(base64.decode(raw)));
        } catch (_) {}
      }
    }
    final burnt = tokensBurntFromTx(map);
    audit.add(AuditEntry(
      txHash: txHash,
      method: method,
      account: accountId,
      matchId: matchIdFromArgs(args, map),
      tokensBurnt: burnt,
      tgas: (map['tgas'] as double?) ?? 0,
    ));
    return map;
  }

  /// `view_account` balance in yoctoNEAR.
  Future<BigInt> balance() async {
    final res = await _rpc('query', {
      'request_type': 'view_account',
      'finality': 'optimistic',
      'account_id': accountId,
    });
    return BigInt.parse(res['amount'] as String);
  }

  /// Next access-key nonce, cached after the first `view_access_key`.
  Future<int> _nextNonce() async {
    if (_nonce != null) {
      _nonce = _nonce! + 1;
      return _nonce!;
    }
    final access = await _rpc('query', {
      'request_type': 'view_access_key',
      'finality': 'optimistic',
      'account_id': accountId,
      'public_key': publicKey,
    });
    _nonce = (access['nonce'] as int) + 1;
    return _nonce!;
  }

  /// Final block hash for a new transaction, fetched at most every
  /// [_blockHashFor].
  Future<Uint8List> _recentBlockHash() async {
    final at = _blockHashAt;
    final cached = _blockHash;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _blockHashFor) {
      return cached;
    }
    final block = await _rpc('block', {'finality': 'final'});
    final hash = Uint8List.fromList(
      base58.decode(block['header']['hash'] as String),
    );
    _blockHash = hash;
    _blockHashAt = DateTime.now();
    return hash;
  }

  /// Polls `tx` for [txHash] after a commit that timed out. Throws a
  /// `TimeoutException` if the chain still has no result.
  Future<Map<String, dynamic>> _awaitTx(String txHash) async {
    Object? last;
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      try {
        final res = await _rpc('tx', [txHash, accountId]);
        return Map<String, dynamic>.from(res as Map);
      } catch (e) {
        last = e;
      }
    }
    throw TimeoutException('NEAR did not confirm the transaction: $last');
  }

  /// Moves to the next endpoint and drops the pooled connection.
  void _rotate() {
    _rpcIndex++;
    _rotatedAt = DateTime.now();
    _http.close();
    _http = http.Client();
  }

  /// POST JSON-RPC with a deadline.
  ///
  /// A 429 backs off and rotates. A dead or stalled socket rotates once and
  /// retries reads; a stalled `broadcast_tx_commit` is surfaced as a
  /// `TimeoutException` so [call] can look the transaction up by hash.
  Future<dynamic> _rpc(
    String method,
    Object params, {
    Duration timeout = _readTimeout,
  }) async {
    final rotated = _rotatedAt;
    if (rotated != null && DateTime.now().difference(rotated) > _fallbackFor) {
      _rpcIndex = 0;
      _rotatedAt = null;
    }
    final isCommit = method == 'broadcast_tx_commit';
    Object? last;
    var networkFailures = 0;
    for (var attempt = 0; attempt < _endpoints.length * 3; attempt++) {
      final url = _endpoints[_rpcIndex % _endpoints.length];
      final http.Response res;
      try {
        res = await _http
            .post(
              Uri.parse(url),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'jsonrpc': '2.0',
                'id': 'engkwentro',
                'method': method,
                'params': params,
              }),
            )
            .timeout(timeout);
      } on TimeoutException {
        _rotate();
        if (isCommit) rethrow;
        last = TimeoutException('NEAR RPC $method timed out at $url');
        if (++networkFailures > 1) break;
        continue;
      } catch (e) {
        // Socket reset, DNS failure, stale keep-alive connection.
        _rotate();
        last = StateError('NEAR RPC $method: network error at $url: $e');
        if (++networkFailures > 1) break;
        continue;
      }
      if (res.statusCode == 429) {
        last = StateError('NEAR RPC $method: 429 from $url');
        _rotate();
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        continue;
      }
      if (res.body.isEmpty) {
        throw StateError(
          'NEAR RPC $method: empty body ${res.statusCode} from $url',
        );
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['error'] != null) {
        final err = body['error'].toString();
        if (err.contains('429') || err.contains('rate')) {
          last = StateError('NEAR RPC $method: $err');
          _rotate();
          await Future<void>.delayed(
            Duration(milliseconds: 400 * (attempt + 1)),
          );
          continue;
        }
        throw StateError('NEAR RPC $method: ${body['error']}');
      }
      return body['result'];
    }
    throw last ?? StateError('NEAR RPC $method failed');
  }

  /// Borsh FunctionCall transaction (one action).
  Uint8List _transaction({
    required int nonce,
    required Uint8List blockHash,
    required String method,
    required List<int> args,
    required int gas,
    required BigInt deposit,
  }) {
    final w = _Writer()
      ..str(accountId)
      ..byte(0)
      ..bytes(_pub!)
      ..u64(nonce)
      ..str(contractId)
      ..bytes(blockHash)
      ..u32(1)
      ..byte(2)
      ..str(method)
      ..u32(args.length)
      ..bytes(args)
      ..u64(gas)
      ..u128(deposit);
    return w.take();
  }
}

/// Preferred RPC first, then FastNEAR, then the official endpoint.
List<String> _rpcList(String preferred) {
  const fallbacks = [
    'https://rpc.testnet.fastnear.com',
    'https://test.rpc.fastnear.com',
    'https://rpc.testnet.near.org',
  ];
  return [
    if (preferred.isNotEmpty && !preferred.contains('rpc.testnet.near.org')) preferred,
    ...fallbacks,
  ];
}

/// Strips an `ed25519:` prefix and base58-decodes the rest.
Uint8List _decodeKey(String key) {
  final raw = key.contains(':') ? key.split(':').last : key;
  return Uint8List.fromList(base58.decode(raw));
}

/// Little-endian borsh writer for a single FunctionCall tx.
class _Writer {
  final BytesBuilder _b = BytesBuilder();

  /// One unsigned byte.
  void byte(int v) => _b.addByte(v);

  /// Raw bytes, no length prefix.
  void bytes(List<int> v) => _b.add(v);

  /// Little-endian u32.
  void u32(int v) {
    final n = ByteData(4)..setUint32(0, v, Endian.little);
    _b.add(n.buffer.asUint8List());
  }

  /// Little-endian u64.
  void u64(int v) {
    final n = ByteData(8)..setUint64(0, v, Endian.little);
    _b.add(n.buffer.asUint8List());
  }

  /// Little-endian u128.
  void u128(BigInt v) {
    var x = v;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    _b.add(out);
  }

  /// Borsh string: u32 length, then UTF-8.
  void str(String s) {
    final u = utf8.encode(s);
    u32(u.length);
    bytes(u);
  }

  /// Consumes the buffer.
  Uint8List take() => _b.toBytes();
}

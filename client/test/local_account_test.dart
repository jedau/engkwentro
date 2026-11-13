import 'dart:convert';

import 'package:engkwentro/local_account.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('create posts faucet and persists credentials', () async {
    FlutterSecureStorage.setMockInitialValues({});
    String? postedBody;
    final client = MockClient((request) async {
      postedBody = request.body;
      expect(request.url.host, 'helper.testnet.near.org');
      expect(request.method, 'POST');
      return http.Response('{}', 200);
    });

    final factory = LocalAccountFactory(client: client);
    final account = await factory.create(preferredName: 'engkwentro-qa');

    expect(account.accountId, 'engkwentro-qa.testnet');
    expect(account.privateKey, startsWith('ed25519:'));
    final body = jsonDecode(postedBody!) as Map<String, dynamic>;
    expect(body['newAccountId'], 'engkwentro-qa.testnet');
    expect(body['newAccountPublicKey'], startsWith('ed25519:'));

    final restored = await factory.restore();
    expect(restored?.accountId, account.accountId);
    expect(restored?.privateKey, account.privateKey);

    await factory.clear();
    expect(await factory.restore(), isNull);
  });

  test('empty preferred name yields player-*.testnet', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final client = MockClient((_) async => http.Response('{}', 200));
    final factory = LocalAccountFactory(client: client);
    final account = await factory.create();
    expect(account.accountId, matches(r'^player-[a-z0-9]+\.testnet$'));
  });
}

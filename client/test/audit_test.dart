import 'package:engkwentro/audit.dart';
import 'package:flutter_test/flutter_test.dart';

/// [matchIdFromArgs] and [tokensBurntFromTx].
void main() {
  test('match id comes from args or create result', () {
    expect(matchIdFromArgs({'match_id': 6}, {}), 6);
    expect(matchIdFromArgs(<String, dynamic>{}, {'decoded': 6}), 6);
    expect(matchIdFromArgs(<String, dynamic>{}, {'decoded': [7, 'K7M2P9QWX4R8']}), 7);
    expect(matchIdFromArgs(<String, dynamic>{}, {}), isNull);
  });

  test('tokens burnt sums receipt outcomes', () {
    final tx = {
      'transaction_outcome': {
        'outcome': {'tokens_burnt': '100', 'gas_burnt': '2000000000000'},
      },
      'receipts_outcome': [
        {
          'outcome': {'tokens_burnt': '50', 'gas_burnt': '500000000000'},
        },
      ],
    };
    expect(tokensBurntFromTx(tx), '150');
    expect(tx['tgas'], 2.5);
  });
}

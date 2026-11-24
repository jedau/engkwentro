import 'package:engkwentro/stake.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats free, tenth, and whole NEAR', () {
    expect(formatNearYocto('0'), 'Free');
    expect(formatNearYocto(tenthNearYocto), '0.1 NEAR');
    expect(formatNearYocto(nearYocto), '1 NEAR');
    expect(formatPotYocto('0'), 'Free match');
    expect(formatPotYocto(nearYocto), 'Pot 2 NEAR');
    expect(formatPotYocto(tenthNearYocto), 'Pot 0.2 NEAR');
  });

  test('parses typed NEAR into yocto', () {
    expect(nearTextToYocto('0'), '0');
    expect(nearTextToYocto(''), '0');
    expect(nearTextToYocto('1'), nearYocto);
    expect(nearTextToYocto('0.1'), tenthNearYocto);
    expect(
      nearTextToYocto('.5'),
      (BigInt.parse(nearYocto) ~/ BigInt.two).toString(),
    );
    expect(nearTextToYocto('-1'), isNull);
    expect(nearTextToYocto('abc'), isNull);
  });

  test('payout split matches 1.5% rake on the pot', () {
    final free = payoutSplit('0');
    expect(free.winner, BigInt.zero);
    expect(free.rake, BigInt.zero);

    // stake 10_000 yocto → pot 20_000 → rake 300 → winner 19_700
    final split = payoutSplit('10000');
    expect(split.pot, BigInt.from(20000));
    expect(split.rake, BigInt.from(300));
    expect(split.winner, BigInt.from(19700));
  });

  test('caption explains free vs winner / rake', () {
    expect(stakePayoutCaption('0'), contains('does not wager anything'));
    final oneNear = stakePayoutCaption(nearYocto);
    expect(oneNear, contains('Winner wins'));
    expect(oneNear, contains('App takes'));
    expect(oneNear, contains('1.5%'));
  });
}

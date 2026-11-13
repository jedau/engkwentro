import 'package:engkwentro/auth.dart';
import 'package:engkwentro/wallet_chooser.dart';
import 'package:engkwentro/wallet_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registry lists WalletConnect first', () {
    final list = WalletRegistry.forTestnet(includeMainnetOnly: true);
    expect(list.first.id, 'walletconnect');
    expect(list.first.kind, WalletConnectKind.walletConnect);
    expect(list.any((w) => w.id == 'intear'), isTrue);
  });

  testWidgets('chooser shows WC logo row before other wallets', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WalletOnboardingSheet(
            auth: AuthController.forTest(),
            onDone: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final wc = tester.getTopLeft(find.text('WalletConnect'));
    final intear = tester.getTopLeft(find.text('Intear Wallet'));
    expect(wc.dy, lessThan(intear.dy));
    expect(find.byType(Image), findsWidgets);
  });
}

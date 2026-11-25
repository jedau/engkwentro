// Home create/join modals; match screen only after success.
import 'package:engkwentro/auth.dart';
import 'package:engkwentro/main.dart';
import 'package:engkwentro/net_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _alice = NetConfig(
  roleA: true,
  account: 'player1.engkwentro.testnet',
  key: 'ed25519:11111111111111111111111111111111',
  opponent: '',
  contract: 'play.engkwentro.testnet',
  rpc: 'https://rpc.testnet.fastnear.com',
  mailbox: 'http://127.0.0.1:8787',
);

final _loggedIn = AuthController.forTest(
  session: const AuthSession(
    accountId: 'player1.engkwentro.testnet',
    privateKey: 'ed25519:11111111111111111111111111111111',
    source: AuthSource.demo,
  ),
);

/// Runs the home and lobby cases.
void main() {
  testWidgets('home is connect-gated create join, not a local match', (
    tester,
  ) async {
    await tester.pumpWidget(EngkwentroApp(auth: AuthController.forTest()));
    expect(find.byKey(const ValueKey('brand-logo')), findsOneWidget);
    expect(find.byKey(const ValueKey('connect-wallet')), findsOneWidget);
    expect(find.text('CONNECT'), findsOneWidget);
    expect(find.text('WALLET'), findsOneWidget);
    expect(find.text('CREATE MATCH'), findsNothing);
    expect(find.text('JOIN MATCH'), findsNothing);
    expect(find.text('Start a local match'), findsNothing);
  });

  testWidgets('login sheet offers create, WalletConnect, and demo', (
    tester,
  ) async {
    await tester.pumpWidget(EngkwentroApp(auth: AuthController.forTest()));
    await tester.tap(find.byKey(const ValueKey('connect-wallet')));
    await tester.pumpAndSettle();
    expect(find.text('Create play account'), findsOneWidget);
    expect(find.text('CREATE PLAY ACCOUNT'), findsOneWidget);
    // Backup UI appears only after a successful create (not auto-dismiss).
    expect(find.text('WalletConnect'), findsOneWidget);
    expect(find.text('Intear Wallet'), findsOneWidget);
    expect(find.text('DEMO ALICE'), findsOneWidget);
  });

  testWidgets('create opens a confirm dialog when logged in', (tester) async {
    await tester.pumpWidget(EngkwentroApp(auth: _loggedIn));
    await tester.tap(find.text('CREATE MATCH'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('open challenge'), findsOneWidget);
    expect(
      find.textContaining('First mover is set when the opponent accepts'),
      findsOneWidget,
    );
    expect(find.textContaining('does not wager anything'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Commit army'), findsNothing);
  });

  testWidgets('join opens a key dialog when logged in', (tester) async {
    await tester.pumpWidget(EngkwentroApp(auth: _loggedIn));
    await tester.tap(find.text('JOIN MATCH'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Join match'), findsOneWidget);
    expect(find.textContaining('Match key'), findsOneWidget);
    expect(find.text('Commit army'), findsNothing);
  });

  testWidgets('join dialog closes without a disposed controller error', (
    tester,
  ) async {
    await tester.pumpWidget(EngkwentroApp(auth: _loggedIn));
    await tester.tap(find.text('JOIN MATCH'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ABCD-EFGH-IJKL');
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready session without match id shows boot, not lobby form', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NetPlayPage(onExit: () {}, config: _alice),
      ),
    );
    await tester.pump();
    expect(find.text('Match key'), findsNothing);
    expect(find.text('Commit army'), findsNothing);
  });

  testWidgets('home logo scales to the phone width', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(EngkwentroApp(auth: AuthController.forTest()));
    final logo = tester.getRect(find.byKey(const ValueKey('brand-logo')));
    expect(logo.left, greaterThanOrEqualTo(0));
    expect(logo.right, lessThanOrEqualTo(430));
    expect(logo.width, greaterThan(300));
    expect(logo.height, greaterThan(200));
  });

  testWidgets('home stays inside a short phone viewport', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(EngkwentroApp(auth: _loggedIn));
    final join = tester.getRect(find.text('JOIN MATCH'));
    expect(join.left, greaterThanOrEqualTo(0));
    expect(join.right, lessThanOrEqualTo(320));
  });
}

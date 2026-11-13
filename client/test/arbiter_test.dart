import 'dart:typed_data';

import 'package:engkwentro/arbiter.g.dart';
import 'package:engkwentro/commit.dart';
import 'package:engkwentro/game.dart';
import 'package:engkwentro/mailbox.dart';
import 'package:engkwentro/match_store.dart';
import 'package:engkwentro/near.dart';
import 'package:engkwentro/net_play.dart';
import 'package:engkwentro/ot.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline session for setup-state tests; no RPC call is made.
NetSession _session({bool sideA = true}) => NetSession(
  near: NearClient(
    rpcUrl: 'http://127.0.0.1:3030',
    accountId: sideA
        ? 'player1.engkwentro.testnet'
        : 'player2.engkwentro.testnet',
    privateKey: 'ed25519:11111111111111111111111111111111',
    contractId: 'play.engkwentro.testnet',
  ),
  mailbox: Mailbox('http://127.0.0.1:8787'),
  sideA: sideA,
  opponent: 'opponent.engkwentro.testnet',
);

/// Matrix, commitments, local engine, and sealed OT.
void main() {
  test('composition is 21', () {
    expect(composition.values.fold<int>(0, (a, b) => a + b), 21);
    expect(composition[Rank.spy], 2);
    expect(composition[Rank.private], 6);
  });

  test('matrix is 15x15', () {
    expect(matrix.length, 15);
    for (final row in matrix) {
      expect(row.length, 15);
    }
  });

  test('flag is captured by anything except it already winning vs flag', () {
    expect(resolve(Rank.private, Rank.flag), Exchange.attackerWins);
    expect(endsGame(Rank.flag), isTrue);
    expect(resolve(Rank.flag, Rank.private), Exchange.defenderWins);
  });

  test('default armies are legal and A can move', () {
    final g = MatchGame.standard();
    expect(g.hasMove(Side.a), isTrue);
    expect(g.hasMove(Side.b), isTrue);
    expect(g.play(MatchGame.sq(8, 1), MatchGame.sq(8, 2)), isNull);
    expect(g.toMove, Side.b);
  });

  test('default home squares are 21', () {
    expect(homeSquares(true), hasLength(21));
    expect(homeSquares(false), hasLength(21));
    expect(homeSquares(true).last, (2, 2));
    expect(homeSquares(false).last, (8, 7));
    // Bob's forward three are wire 6–8 so Alice sees them on columns 7–9.
    expect(
      homeSquares(false).where((s) => s.$2 == 5).map((s) => s.$1).toList(),
      [6, 7, 8],
    );
  });

  test('commitment changes with rank', () {
    final salt = List<int>.filled(32, 7);
    expect(
      pieceCommitment(Rank.private, salt),
      isNot(pieceCommitment(Rank.flag, salt)),
    );
  });

  test('local OT matches resolve', () {
    expect(localExchange(Rank.spy, Rank.private), Exchange.defenderWins);
    expect(
      otReceive(otSenderRow(Rank.spy), Rank.private),
      Exchange.defenderWins,
    );
  });

  test('sealed OT opens only the defender column', () async {
    final offer = await otOffer(Rank.private);
    final sealed = await otSealRow(Rank.spy, offer.publicKeys);
    expect(
      await otOpenCell(sealed, Rank.private, offer.secret!),
      Exchange.defenderWins,
    );
  });

  test('same offer still opens after a second seal', () async {
    final offer = await otOffer(Rank.captain);
    final first = await otSealRow(Rank.private, offer.publicKeys);
    final second = await otSealRow(Rank.private, offer.publicKeys);
    expect(
      await otOpenCell(first, Rank.captain, offer.secret!),
      Exchange.defenderWins,
    );
    expect(
      await otOpenCell(second, Rank.captain, offer.secret!),
      Exchange.defenderWins,
    );
  });

  test('setup starts empty, places only on home rows, and lifts', () {
    final s = _session();
    expect(s.setupRemaining, 21);

    s.selectSetupRank(Rank.flag);
    expect(s.setupSelected, Rank.flag);
    s.setupTap(MatchGame.sq(0, 7));
    expect(s.setupRemaining, 21, reason: 'enemy home is rejected');

    final home = MatchGame.sq(4, 0);
    s.setupTap(home);
    expect(s.setupRankAt(home), Rank.flag);
    expect(s.setupRemaining, 20);
    expect(s.setupSelected, isNull);

    s.setupTap(home);
    expect(s.setupRankAt(home), isNull);
    expect(s.setupRemaining, 21);
    expect(s.setupSelected, Rank.flag);
  });

  test('auto-fill places the whole composition on own home rows', () {
    final s = _session(sideA: false);
    s.setupAutoFill();
    expect(s.setup.length, 21);
    expect(s.setupRemaining, 0);
    expect(
      s.setup.keys.every(
        (square) => MatchGame.homeB.contains(MatchGame.rankOf(square)),
      ),
      isTrue,
    );
    for (final rank in Rank.values) {
      expect(
        s.setup.values.where((placed) => placed == rank).length,
        composition[rank],
      );
    }
    s.setupClear();
    expect(s.setupRemaining, 21);
    expect(s.setupSelected, isNull);
  });

  test('commitArmy rejects an incomplete setup', () async {
    final s = _session();
    await expectLater(s.commitArmy(), throwsStateError);
  });

  test('committed army stays visible until occupancy loads', () {
    final s = _session()
      ..accepted = true
      ..matchId = 7
      ..setupAutoFill();
    expect(s.settingUp, isTrue);
    expect(s.showSetupBoard, isTrue);

    s.rosterReady = true;
    expect(s.settingUp, isFalse);
    expect(s.showSetupBoard, isTrue);

    s.occupancy[0] = 1;
    expect(s.showSetupBoard, isFalse);
  });

  test('activity shows Battle! while waiting on a fight', () {
    final s = _session()
      ..occupancy[0] = 1
      ..occupancy[1] = 22
      ..play = PlaySnap('WaitingForArbiter', 'A', 1, 0, 0, 1);
    expect(s.waitingIsFight(), isTrue);
    final copy = s.activity()!;
    expect(copy.title, 'Battle!');
    expect(copy.subtitle, 'Resolving…');
    s.progress = 'Waiting for defender…';
    expect(s.activity()!.subtitle, 'Waiting for defender…');
    expect(s.statusLine, isNot('Your turn'));
  });

  test('a quiet step onto the far rank is an arrival, not a fight', () {
    // Alice stepped 62 -> 71: her piece is already on the destination and
    // the source is empty. The mover must report an arrival, as the
    // contract expects, on both phones.
    for (final sideA in [true, false]) {
      final s = _session(sideA: sideA)
        ..occupancy[71] = 5
        ..play = PlaySnap('WaitingForArbiter', 'A', 9, 8, 62, 71);
      expect(s.waitingIsFight(), isFalse, reason: 'sideA=$sideA');
      expect(s.activity()!.title, 'Moving…');
    }
  });

  test('the turn comes only from the sync row', () {
    final s = _session()
      ..accepted = true
      ..rosterReady = true
      ..matchId = 7
      ..play = PlaySnap('InProgress', 'A', 0, 0, 255, 255, paused: false);
    expect(s.myTurn, isTrue);
    s.play = PlaySnap('InProgress', 'B', 1, 0, 255, 255, paused: false);
    expect(s.myTurn, isFalse);
    expect(s.statusLine, "Opponent's turn");
    s.play = PlaySnap('InProgress', '', 1, 0, 255, 255, paused: false);
    expect(s.myTurn, isFalse);
  });

  test('formatClock floors and never goes negative', () {
    expect(formatClock(const Duration(seconds: 90)), '1:30');
    expect(formatClock(const Duration(milliseconds: 59999)), '0:59');
    expect(formatClock(const Duration(seconds: -3)), '0:00');
    expect(formatClock(const Duration(hours: 1, seconds: 5)), '1:00:05');
  });

  test('graveyard lists only missing own pieces', () {
    final s = _session()
      ..accepted = true
      ..matchId = 7
      ..rosterReady = true
      ..ranks = List<Rank>.generate(
        21,
        (i) => Rank.values[i % Rank.values.length],
      )
      ..salts = List.generate(21, (_) => Uint8List(32))
      ..squares = List.generate(21, (i) => (i % 9, i ~/ 9));

    for (var i = 0; i < 21; i++) {
      s.occupancy[i] = i + 1;
    }
    s.occupancy[30] = 22;
    s.occupancy[0] = 0;
    s.occupancy[1] = 0;
    s.syncGraveyard();
    expect(s.myGraveyard, hasLength(2));
    expect(s.graveyardOcc, isNot(contains(22)));
    expect(s.myGraveyard.first, s.ranks[0]);
  });

  test('match local state roundtrips ranks and salts', () {
    final salt = Uint8List.fromList(List<int>.filled(32, 9));
    final saved = MatchLocalState(
      matchId: 42,
      joinKey: 'ABCDEFGHJKLM',
      accountId: 'player1.engkwentro.testnet',
      sideA: true,
      rosterReady: true,
      ranks: [Rank.flag, Rank.spy],
      squares: [(1, 0), (2, 0)],
      salts: [salt, salt],
    );
    final loaded = MatchLocalState.fromJson(saved.toJson());
    expect(loaded.matchId, 42);
    expect(loaded.joinKey, 'ABCDEFGHJKLM');
    expect(loaded.rosterReady, isTrue);
    expect(loaded.ranks, [Rank.flag, Rank.spy]);
    expect(loaded.squares, [(1, 0), (2, 0)]);
    expect(loaded.salts.first, salt);
  });
}

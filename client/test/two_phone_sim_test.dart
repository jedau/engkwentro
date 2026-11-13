// Two phones, one chain, simulated time.
//
// Both phones run the real NetSession and MatchDriver. Only the network is
// replaced: a model of the match contract on a chain with 600 ms blocks,
// reached over connections with latency, nodes that answer from old blocks,
// requests that stall and transactions that get lost. An observer samples
// both screens every 50 ms and records anything that should not be there.
//
// Run with `flutter test test/two_phone_sim_test.dart -r expanded` to see
// the measured numbers.

import 'dart:async';

import 'package:engkwentro/arbiter.g.dart';
import 'package:engkwentro/game.dart';
import 'package:engkwentro/net_driver.dart';
import 'package:engkwentro/net_play.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chain.dart';
import 'support/two_phones.dart';

const _ms = 1000000;

/// Two phones at one table.
class _Table {
  _Table(
    this.async, {
    required NetProfile netA,
    required NetProfile netB,
    int seed = 1,
    this.clockMinutes = 15,
  }) : chain = FakeChain(elapsed: () => async.elapsed, seed: seed) {
    final blobs = <String, String>{};
    // Deliberately unrelated local clocks: nothing may depend on the two
    // phones agreeing about the time.
    alice = _phone('alice', 'alice.testnet', netA, blobs, 12345 * sec, true);
    bob = _phone('bob', 'bob.testnet', netB, blobs, 987654 * sec, false);
  }

  final FakeAsync async;
  final FakeChain chain;
  final int clockMinutes;
  late final Phone alice;
  late final Phone bob;
  Timer? _ticker;

  Phone _phone(
    String name,
    String account,
    NetProfile net,
    Map<String, String> blobs,
    int monoBase,
    bool sideA,
  ) {
    final session = NetSession(
      near: FakeNear(chain, account, net),
      mailbox: FakeMailbox(blobs, net),
      sideA: sideA,
      opponent: '',
      monoNs: () => monoBase + async.elapsed.inMicroseconds * 1000,
    )..persist = false;
    return Phone(name, session);
  }

  int get nowMs => async.elapsed.inMilliseconds;

  void until(bool Function() done, {int seconds = 60, String what = ''}) {
    final deadline = nowMs + seconds * 1000;
    while (!done()) {
      if (nowMs >= deadline) {
        fail('timed out after ${seconds}s waiting for $what\n'
            'chain=${chain.state} running="${chain.runningSide}"\n'
            'alice: ${alice.session.statusLine} / ${alice.session.activity()} '
            'errors=${alice.errors}\n'
            'bob: ${bob.session.statusLine} / ${bob.session.activity()} '
            'errors=${bob.errors}');
      }
      async.elapse(const Duration(milliseconds: 50));
    }
  }

  /// Create, join, arrange and start, the way the app does it.
  void kickoff() {
    alice.driver.run(() => alice.session.create(clockMinutes: clockMinutes));
    until(() => alice.session.joinKey != null, what: 'create');
    bob.driver.run(() => bob.session.acceptKey(alice.session.joinKey!));
    until(
      () => alice.session.accepted && bob.session.matchId != null,
      what: 'join',
    );
    for (final p in [alice, bob]) {
      p.session.setupAutoFill();
      // The default layout leaves Bob's flag in his front row, which ends a
      // random game in a few moves. Tuck both flags into a back corner.
      final setup = p.session.setup;
      final flagAt = setup.keys.firstWhere((sq) => setup[sq] == Rank.flag);
      final corner = p.session.sideA ? MatchGame.sq(0, 0) : MatchGame.sq(8, 7);
      final other = setup[corner]!;
      setup[corner] = Rank.flag;
      setup[flagAt] = other;
    }
    alice.driver.run(alice.session.confirmRoster);
    async.elapse(const Duration(milliseconds: 2500));
    bob.driver.run(bob.session.confirmRoster);
    until(
      () =>
          (alice.session.play?.live ?? false) &&
          (bob.session.play?.live ?? false),
      what: 'kickoff',
    );
  }

  Truth truth() => Truth(
    runningSide: chain.runningSide,
    turnStartedAtNs: chain.turnStartedAtNs,
    nowNs: chain.nowNs,
    ended: chain.state == 'Ended',
  );

  /// Lets two bots play until [moves] have landed or the match ends.
  Observer play({
    required int moves,
    int seed = 7,
    int capSeconds = 900,
    double attackBias = 0.6,
  }) {
    final obs = Observer(
      alice,
      bob,
      Bot(alice, seed: seed, attackBias: attackBias),
      Bot(bob, seed: seed + 1, attackBias: attackBias),
      truth: truth,
    );
    _ticker = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => obs.tick(nowMs),
    );
    until(
      () => chain.moves.length >= moves || chain.state == 'Ended',
      seconds: capSeconds,
      what: '$moves moves',
    );
    return obs;
  }

  /// Resigns if needed, then waits for both phones to flip and settle.
  void finish(Observer obs) {
    obs.botA.paused = true;
    obs.botB.paused = true;
    until(
      () => alice.session.pending == null && bob.session.pending == null,
      what: 'moves in flight',
    );
    // On a bad connection a resignation can be lost like anything else;
    // a player would press the button again.
    for (var tries = 0; tries < 8 && chain.state != 'Ended'; tries++) {
      until(
        () => chain.state != 'WaitingForArbiter',
        seconds: 300,
        what: 'open fight',
      );
      if (chain.state == 'Ended') break;
      alice.driver.run(alice.session.resign);
      until(() => !alice.session.busy, seconds: 120, what: 'resign');
    }
    until(
      () => alice.session.finished && bob.session.finished,
      seconds: 600,
      what: 'settlement',
    );
    obs.finish(nowMs);
    close();
  }

  void close() {
    _ticker?.cancel();
    alice.driver.stop();
    bob.driver.stop();
  }
}

/// Chain-side fairness: what each move was charged against what the player
/// actually spent looking at "Your turn".
String _fairness(_Table t, Observer obs) {
  final overcharge = <int>[];
  final network = <int>[];
  for (final mv in t.chain.moves) {
    final bot = mv.side == t.alice.side ? obs.botA : obs.botB;
    final tap = bot.taps.where((x) => x.landed && x.nonce == mv.nonce);
    if (tap.isEmpty) continue;
    overcharge.add(mv.chargedNs ~/ _ms - tap.first.thoughtMs);
    network.add((mv.turnNs - mv.chargedNs) ~/ _ms);
  }
  String dist(List<int> xs) {
    if (xs.isEmpty) return 'none';
    final s = [...xs]..sort();
    return 'n=${s.length} p50=${s[s.length ~/ 2]} p90=${s[(s.length * 9) ~/ 10]} '
        'min=${s.first} max=${s.last} ms';
  }

  return 'charged minus time "Your turn" was on screen: ${dist(overcharge)}\n'
      'network time per move not charged to anyone: ${dist(network)}';
}

void main() {
  test('driver cadence', () {
    final d = MatchDriver(
      NetSession(
        near: FakeNear(FakeChain(elapsed: () => Duration.zero), 'a.testnet', NetProfile(seed: 1)),
        mailbox: FakeMailbox({}, NetProfile(seed: 1)),
        sideA: true,
        opponent: '',
      ),
    );
    expect(d.idleEvery, const Duration(seconds: 1));
    expect(d.fastEvery, lessThanOrEqualTo(const Duration(milliseconds: 300)));
  });

  test('normal network, tap notes off: same invariants, larger corrections', () {
    FakeAsync().run((async) {
      final t = _Table(async, netA: NetProfile(seed: 11), netB: NetProfile(seed: 12));
      t.alice.session.tapNotes = false;
      t.bob.session.tapNotes = false;
      t.kickoff();
      final obs = t.play(moves: 70);
      t.finish(obs);
      // ignore: avoid_print
      print('${obs.report('normal network, tap notes off')}\n${_fairness(t, obs)}');

      expect(obs.violations, isEmpty, reason: obs.violations.take(8).join('\n'));
      expect(obs.ownClockUps, isEmpty);
      expect(obs.faceVsBankNs.every((d) => d == 0), isTrue);
      expect(obs.restDisagreementNs, 0);
      // Nothing about a clock went through the mailbox.
      expect(t.alice.session.tapNotesUsed + t.bob.session.tapNotesUsed, 0);
    });
  });

  test('normal network: a full game, every screen invariant holds', () {
    FakeAsync().run((async) {
      final t = _Table(async, netA: NetProfile(seed: 11), netB: NetProfile(seed: 12));
      t.kickoff();
      final obs = t.play(moves: 70);
      t.finish(obs);
      // ignore: avoid_print
      print('${obs.report('normal network')}\n${_fairness(t, obs)}');

      expect(obs.violations, isEmpty, reason: obs.violations.take(8).join('\n'));
      expect(obs.ownClockUps, isEmpty);
      expect(t.alice.errors, isEmpty);
      expect(t.bob.errors, isEmpty);
      // The clock a player sees when they tap is the clock they keep.
      expect(obs.faceVsBankNs.every((d) => d == 0), isTrue);
      // Clocks that are not running read the same on both phones.
      expect(obs.restDisagreementNs, 0);
      // One writer: a phone never has two requests to NEAR in flight.
      expect((t.alice.session.near as FakeNear).maxInFlight, 1);
      expect((t.bob.session.near as FakeNear).maxInFlight, 1);
      // Nobody pays for the network on a normal connection.
      for (final mv in t.chain.moves) {
        expect(mv.chargedNs, mv.claimedThinkNs, reason: 'move ${mv.side}${mv.nonce}');
      }
      expect(t.chain.moves.length, greaterThanOrEqualTo(20));
    });
  });

  for (final seed in [1, 2, 3, 4, 5, 6]) {
    test('rough network #$seed: stalls, stale nodes and lost transactions', () {
      FakeAsync().run((async) {
        final t = _Table(
          async,
          netA: NetProfile.rough(20 + seed),
          netB: NetProfile.rough(40 + seed),
          seed: seed,
        );
        t.kickoff();
        final obs = t.play(
          moves: 60,
          seed: 30 + seed,
          capSeconds: 3600,
          attackBias: 0.9,
        );
        t.finish(obs);
        // ignore: avoid_print
        print('${obs.report('rough network #$seed')}\n${_fairness(t, obs)}');

        // Latency may be anything; what is on screen must still be true.
        expect(obs.violations, isEmpty, reason: obs.violations.take(8).join('\n'));
        expect(obs.ownClockUps, isEmpty);
        expect(obs.restDisagreementNs, 0);
        // The stale-reply guard was actually exercised.
        expect(
          t.alice.session.staleDropped + t.bob.session.staleDropped,
          greaterThan(0),
        );
        // The cap bounds what a claim can take back, whatever the network did.
        for (final mv in t.chain.moves) {
          expect(mv.turnNs - mv.chargedNs, lessThanOrEqualTo(lagCapNs));
        }
        expect(t.chain.moves.length, greaterThanOrEqualTo(20));
      });
    });
  }

  test('an outage cannot leave a phone stuck on a stale turn', () {
    FakeAsync().run((async) {
      final netB = _Switchable(seed: 42);
      final t = _Table(async, netA: NetProfile(seed: 41), netB: netB);
      t.kickoff();
      final obs = t.play(moves: 6);
      obs.botA.paused = true;
      obs.botB.paused = true;
      t.until(
        () =>
            t.alice.session.pending == null &&
            t.bob.session.pending == null &&
            t.chain.state != 'WaitingForArbiter',
        seconds: 120,
        what: 'quiet board',
      );

      // Bob's connection dies. Alice keeps playing if it is her turn.
      netB.down = true;
      obs.botA.paused = false;
      async.elapse(const Duration(seconds: 20));
      netB.down = false;
      obs.botB.paused = false;

      // Within a few seconds of the network returning, whoever is to move
      // on chain sees "Your turn" and the other sees "Opponent's turn".
      t.until(
        () {
          final side = t.chain.runningSide;
          if (side.isEmpty) return false;
          final mover = side == t.alice.side ? t.alice : t.bob;
          final other = side == t.alice.side ? t.bob : t.alice;
          return mover.session.statusLine == 'Your turn' &&
              other.session.statusLine == "Opponent's turn";
        },
        seconds: 12,
        what: 'recovery after the outage',
      );
      // And play carries on from there.
      final before = t.chain.moves.length;
      t.until(() => t.chain.moves.length >= before + 6, seconds: 180, what: 'more moves');
      t.finish(obs);
      expect(obs.ownClockUps, isEmpty);
      expect(
        obs.violations.where((v) => !v.contains('but the chain says')),
        isEmpty,
        reason: obs.violations.take(8).join('\n'),
      );
    });
  });

  test('the same two squares can be fought over twice', () {
    FakeAsync().run((async) {
      final t = _Table(async, netA: NetProfile(seed: 51), netB: NetProfile(seed: 52));
      t.kickoff();
      final a = t.alice.session;
      final b = t.bob.session;
      // Two of Alice's privates against Bob's four-star general, with a
      // spare piece each so the side not fighting has somewhere to step.
      final privates = [
        for (var i = 0; i < 21; i++)
          if (a.ranks[i] == Rank.private) i + 1,
      ];
      final general = b.ranks.indexOf(Rank.general) + 22;
      final x = MatchGame.sq(4, 3);
      final y = MatchGame.sq(4, 4);
      t.chain.edit((occ) {
        occ.fillRange(0, 72, 0);
        occ[x] = privates[0];
        occ[x - 1] = privates[1];
        occ[MatchGame.sq(0, 0)] = privates[2];
        occ[y] = general;
        occ[MatchGame.sq(0, 7)] = b.ranks.indexOf(Rank.sergeant) + 22;
      });
      t.until(
        () => a.occupancy[x] == privates[0] && b.occupancy[x] == privates[0],
        what: 'edited board',
      );

      final bobSpare = MatchGame.sq(0, 7);
      var bobStep = 0;
      void bobFiller() {
        t.until(() => b.canAct, seconds: 60, what: 'Bob to move');
        t.bob.driver.move(bobSpare + bobStep, bobSpare + bobStep + 1);
        bobStep++;
      }

      void aliceMove(int from, int to) {
        if (t.chain.runningSide == t.bob.side) bobFiller();
        t.until(() => a.canAct, seconds: 60, what: 'Alice to move');
        t.alice.driver.move(from, to);
        t.until(() => a.pending == null, seconds: 30, what: 'move to land');
      }

      // First fight on x -> y: the private loses.
      aliceMove(x, y);
      expect(a.activity()?.title, 'Battle!');
      t.until(() => t.chain.state == 'InProgress', seconds: 60, what: 'first fight');
      t.until(() => a.occupancy[x] == 0 && b.occupancy[x] == 0, what: 'board after fight');
      expect(t.chain.occupancy[y], general);

      // Second private steps onto x, then attacks x -> y again.
      aliceMove(x - 1, x);
      t.until(() => t.chain.state == 'InProgress', what: 'quiet step');
      aliceMove(x, y);
      t.until(
        () => t.chain.state == 'InProgress' && t.chain.occupancy[x] == 0,
        seconds: 60,
        what: 'second fight on the same squares',
      );
      t.until(
        () => a.activity() == null && b.activity() == null,
        seconds: 10,
        what: 'overlays down',
      );
      expect(t.chain.occupancy[y], general);
      expect(t.alice.errors, isEmpty);
      expect(t.bob.errors, isEmpty);
      t.close();
    });
  });

  test('a quiet step onto the far rank is confirmed by both phones', () {
    FakeAsync().run((async) {
      final t = _Table(async, netA: NetProfile(seed: 61), netB: NetProfile(seed: 62));
      t.kickoff();
      final a = t.alice.session;
      final b = t.bob.session;
      final runner = a.ranks.indexOf(Rank.captain) + 1;
      final from = MatchGame.sq(4, 6);
      final to = MatchGame.sq(4, 7);
      final bobSpare = MatchGame.sq(0, 5);
      t.chain.edit((occ) {
        occ.fillRange(0, 72, 0);
        occ[from] = runner;
        occ[MatchGame.sq(0, 0)] = a.ranks.indexOf(Rank.sergeant) + 1;
        occ[bobSpare] = b.ranks.indexOf(Rank.sergeant) + 22;
      });
      t.until(() => a.occupancy[from] == runner && b.occupancy[from] == runner, what: 'edited board');
      if (t.chain.runningSide == t.bob.side) {
        t.until(() => b.canAct, what: 'Bob to move');
        t.bob.driver.move(bobSpare, bobSpare + 1);
      }
      t.until(() => a.canAct, seconds: 60, what: 'Alice to move');
      t.alice.driver.move(from, to);
      t.until(() => t.chain.state == 'WaitingForArbiter', what: 'arrival wait');
      t.until(() => a.play?.waiting ?? false, what: 'Alice to see the wait');
      expect(a.waitingIsFight(), isFalse);
      expect(a.activity()?.title, 'Moving…');
      expect(a.statusLine, isNot(contains('Breakthrough')));
      t.until(
        () => t.chain.state == 'InProgress' && t.chain.runningSide == t.bob.side,
        seconds: 30,
        what: 'both arrival reports',
      );
      t.until(
        () => b.statusLine == 'Your turn' && a.statusLine == "Opponent's turn",
        seconds: 10,
        what: 'turn handed to Bob',
      );
      expect(t.chain.occupancy[to], runner);
      expect(t.alice.errors, isEmpty);
      expect(t.bob.errors, isEmpty);
      t.close();
    });
  });

  test('a Flag on the far rank wins if the reply does not challenge it', () {
    FakeAsync().run((async) {
      final t = _Table(async, netA: NetProfile(seed: 81), netB: NetProfile(seed: 82));
      t.kickoff();
      final a = t.alice.session;
      final b = t.bob.session;
      final flag = a.ranks.indexOf(Rank.flag) + 1;
      final from = MatchGame.sq(4, 6);
      final to = MatchGame.sq(4, 7);
      final bobSpare = MatchGame.sq(0, 5);
      final bobStep = MatchGame.sq(1, 5);
      t.chain.edit((occ) {
        occ.fillRange(0, 72, 0);
        occ[from] = flag;
        occ[MatchGame.sq(0, 0)] = a.ranks.indexOf(Rank.sergeant) + 1;
        occ[bobSpare] = b.ranks.indexOf(Rank.sergeant) + 22;
      });
      t.until(() => a.occupancy[from] == flag && b.occupancy[from] == flag, what: 'edited board');
      if (t.chain.runningSide == t.bob.side) {
        t.until(() => b.canAct, what: 'Bob to move');
        t.bob.driver.move(bobSpare, bobStep);
        t.until(() => b.pending == null, what: 'Bob quiet');
      }
      t.until(() => a.canAct, seconds: 60, what: 'Alice to move');
      // No chrome names the home-row step.
      t.alice.driver.move(from, to);
      t.until(() => a.activity()?.title == 'Moving…' || a.play?.waiting == true, what: 'silent confirm');
      t.until(
        () =>
            t.chain.state == 'Breakthrough' &&
            a.play?.state == 'Breakthrough' &&
            b.play?.state == 'Breakthrough',
        seconds: 30,
        what: 'silent breakthrough',
      );
      expect(a.statusLine, "Opponent's turn");
      expect(b.statusLine, 'Your turn');
      expect(a.statusLine.toLowerCase(), isNot(contains('breakthrough')));
      expect(b.statusLine.toLowerCase(), isNot(contains('breakthrough')));
      expect(a.activity(), isNull);
      expect(b.activity(), isNull);
      // Bob moves elsewhere: Alice wins, Flag is revealed.
      final src = b.occupancy[bobSpare] != 0 ? bobSpare : bobStep;
      t.bob.driver.move(src, src + 1);
      t.until(() => t.chain.state == 'Ended', seconds: 30, what: 'breakthrough win');
      t.until(
        () => a.outcomeReason == 'FlagBreakthrough' && b.outcomeReason == 'FlagBreakthrough',
        seconds: 20,
        what: 'both phones see the win',
      );
      expect(a.endCause, 'Flag reached the far rank');
      expect(a.rankOfOcc(flag), Rank.flag);
      expect(t.alice.errors, isEmpty);
      expect(t.bob.errors, isEmpty);
      t.close();
    });
  });

  test('a flag falls only after the lag window, and ends the match', () {
    FakeAsync().run((async) {
      final t = _Table(
        async,
        netA: NetProfile(seed: 71),
        netB: NetProfile(seed: 72),
        clockMinutes: 1,
      );
      t.kickoff();
      final mover = t.chain.runningSide == t.alice.side ? t.alice : t.bob;
      final other = identical(mover, t.alice) ? t.bob : t.alice;
      // Nobody moves. The mover's own clock reaches zero first.
      t.until(() => mover.session.remainingNs(mover.side) == 0, seconds: 70, what: 'zero');
      expect(mover.session.statusLine, 'Out of time');
      expect(mover.session.canAct, isFalse);
      expect(t.chain.state, isNot('Ended'));
      t.until(() => t.chain.state == 'Ended', seconds: 12, what: 'timeout claim');
      final overrun = t.chain.nowNs - t.chain.turnStartedAtNs - 60 * sec;
      expect(overrun, greaterThanOrEqualTo(lagCapNs));
      t.until(
        () => mover.session.outcomeReason == 'Timeout' && other.session.outcomeReason == 'Timeout',
        seconds: 15,
        what: 'both phones to show the result',
      );
      expect(mover.session.endCause, 'Your time expired');
      expect(other.session.endCause, "Opponent's time expired");
      t.close();
    });
  });
}

/// A connection that can be cut and restored.
class _Switchable extends NetProfile {
  _Switchable({required super.seed});

  /// While true every view fails after its deadline and nothing is sent.
  bool down = false;

  @override
  bool roll(double chance) {
    if (down) return true;
    return super.roll(chance);
  }
}

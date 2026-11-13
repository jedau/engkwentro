import 'dart:math';

import 'package:engkwentro/net_driver.dart';
import 'package:engkwentro/net_play.dart';

/// One player's device: a session, the driver the app uses, and what it saw.
class Phone {
  /// Wires a [MatchDriver] to [session] exactly as the match page does.
  Phone(this.name, this.session) {
    driver = MatchDriver(session, onError: errors.add);
  }

  /// Label for reports.
  final String name;

  /// The session under test.
  final NetSession session;

  /// The driver under test.
  late final MatchDriver driver;

  /// Every message the driver would have shown in a snackbar.
  final List<String> errors = [];

  /// `"A"` or `"B"`.
  String get side => session.sideLabel;

  /// The other seat.
  String get them => side == 'A' ? 'B' : 'A';
}

/// One tap, as the player experienced it.
class Tap {
  /// Captured on the frame of the tap.
  Tap({
    required this.phone,
    required this.atMs,
    required this.nonce,
    required this.oppNonce,
    required this.attack,
    required this.thoughtMs,
    required this.faceNs,
  });

  /// Whose tap.
  final Phone phone;

  /// When, on the observer's clock.
  final int atMs;

  /// The mover's nonce for this move.
  final int nonce;

  /// The opponent's nonce at the time.
  final int oppNonce;

  /// True when the tap started a fight.
  final bool attack;

  /// How long "Your turn" had been on screen.
  final int thoughtMs;

  /// The mover's clock at the tap.
  int faceNs;

  /// When the overlay came down, or null while it is still up.
  int? settledAtMs;

  /// True when the chain took the move.
  bool landed = false;

  /// The mover's bank once the chain showed the move.
  int? bankAfterNs;
}

/// Plays one seat the way a person would: waits for "Your turn", thinks,
/// taps a legal move. It only ever looks at what the screen shows.
class Bot {
  /// [attackBias] is how often an available attack is preferred.
  Bot(
    this.phone, {
    required int seed,
    this.attackBias = 0.6,
    this.allowFarRank = false,
  }) : _rng = Random(seed);

  /// The seat this bot plays.
  final Phone phone;

  /// Chance of choosing an attack when one is available.
  final double attackBias;

  /// Whether a quiet step onto the far rank may be chosen.
  final bool allowFarRank;

  final Random _rng;

  /// Every tap made, oldest first.
  final List<Tap> taps = [];

  /// Set to stop tapping.
  bool paused = false;

  int? _turn;
  int _seenAtMs = 0;
  int _dueAtMs = 0;

  /// The newest tap, if any.
  Tap? get last => taps.isEmpty ? null : taps.last;

  int _thinkMs() {
    final roll = _rng.nextDouble();
    if (roll < 0.4) return 150 + _rng.nextInt(850);
    if (roll < 0.9) return 1000 + _rng.nextInt(4000);
    return 5000 + _rng.nextInt(9000);
  }

  /// Called on every observer tick with the observer's clock.
  void tick(int nowMs) {
    final s = phone.session;
    final snap = s.play;
    if (paused || snap == null || !s.canAct) return;
    if (_turn != snap.turnStartedAtNs) {
      _turn = snap.turnStartedAtNs;
      _seenAtMs = nowMs;
      _dueAtMs = nowMs + _thinkMs();
    }
    if (nowMs < _dueAtMs) return;
    final choice = _choose();
    if (choice == null) return;
    final tap = Tap(
      phone: phone,
      atMs: nowMs,
      nonce: snap.nonceOf(phone.side),
      oppNonce: snap.nonceOf(phone.them),
      attack: s.occupancy[choice.$2] != 0,
      thoughtMs: nowMs - _seenAtMs,
      faceNs: s.remainingNs(phone.side),
    );
    taps.add(tap);
    // A failed move leaves the turn with us: try again shortly.
    _dueAtMs = nowMs + 700;
    phone.driver.move(choice.$1, choice.$2);
    // The commitment is made on this very frame.
    final held = s.pending;
    if (held == null) {
      tap.settledAtMs = nowMs;
    } else {
      tap.faceNs = held.faceNs;
    }
  }

  (int, int)? _choose() {
    final s = phone.session;
    final attacks = <(int, int)>[];
    final quiet = <(int, int)>[];
    final farRank = phone.side == 'A' ? 7 : 0;
    for (var from = 0; from < 72; from++) {
      if (!s.mine(s.occupancy[from])) continue;
      for (final to in [from + 9, from - 9, from + 1, from - 1]) {
        if (to < 0 || to > 71 || !s.canMove(from, to)) continue;
        if (s.occupancy[to] != 0) {
          attacks.add((from, to));
        } else if (allowFarRank || to ~/ 9 != farRank) {
          quiet.add((from, to));
        }
      }
    }
    if (attacks.isNotEmpty && (quiet.isEmpty || _rng.nextDouble() < attackBias)) {
      return attacks[_rng.nextInt(attacks.length)];
    }
    if (quiet.isEmpty) return null;
    // Lean forward so the armies actually meet.
    final forward = phone.side == 'A' ? 9 : -9;
    final advancing = [
      for (final m in quiet)
        if (m.$2 - m.$1 == forward) m,
    ];
    final pool = advancing.isNotEmpty && _rng.nextDouble() < 0.7 ? advancing : quiet;
    return pool[_rng.nextInt(pool.length)];
  }
}

/// What "the chain right now" looks like, when the run can know it.
class Truth {
  /// [runningSide] is `"A"`/`"B"` while that clock runs on chain, else `""`.
  Truth({
    required this.runningSide,
    required this.turnStartedAtNs,
    required this.nowNs,
    required this.ended,
  });

  /// True once the match is over on chain.
  final bool ended;

  /// Side whose clock is running on chain, or `""`.
  final String runningSide;

  /// Chain time the current turn began.
  final int turnStartedAtNs;

  /// Chain time now.
  final int nowNs;
}

class _View {
  _View(this.phone);
  final Phone phone;
  int? mineNs;
  int? theirsNs;
  int? theirTurn;
  bool sawTurn = false;
  int? turnKey;
  bool inFight = false;
}

/// Watches both screens at a fixed rate and records every way they could
/// be wrong. Reads only what the widgets read.
class Observer {
  /// [truth] is null on a live run, where the chain cannot be asked for
  /// "now" without going through the same network as the phones.
  Observer(this.a, this.b, this.botA, this.botB, {this.truth, this.tickMs = 50})
    : _va = _View(a),
      _vb = _View(b);

  /// First phone.
  final Phone a;

  /// Second phone.
  final Phone b;

  /// Bot on [a].
  final Bot botA;

  /// Bot on [b].
  final Bot botB;

  /// Ground truth, when available.
  final Truth Function()? truth;

  /// Observer period (ms).
  final int tickMs;

  final _View _va;
  final _View _vb;

  /// Hard failures: things that must never be on screen.
  final List<String> violations = [];

  /// Own clock stepping up (ns). Must stay empty.
  final List<int> ownClockUps = [];

  /// Opponent's clock stepping back up (ns), each a visible rewind.
  final List<int> oppRewinds = [];

  /// Opponent's clock skipping ahead more than time passed (ns).
  final List<int> oppSkips = [];

  /// Tap until the overlay came down (ms).
  final List<int> tapToSettledMs = [];

  /// Bank after the move minus the clock face at the tap (ns).
  final List<int> faceVsBankNs = [];

  /// Lengths of stretches where both screens said "Opponent's turn" (ms).
  final List<int> bothWaitingMs = [];

  /// Chain turn start until "Your turn" was on screen (ms).
  final List<int> noticeMs = [];

  /// A resting clock read differently on the two phones (ns).
  int restDisagreementNs = 0;

  /// Largest gap between a running clock on its own phone and on the
  /// other phone (ns).
  int runningDisagreementNs = 0;

  int _bothSince = -1;
  int _lastMs = -1;

  /// Number of samples taken.
  int samples = 0;

  /// Takes one sample. Call every [tickMs].
  void tick(int nowMs) {
    samples++;
    botA.tick(nowMs);
    botB.tick(nowMs);
    final dtNs = _lastMs < 0 ? 0 : (nowMs - _lastMs) * 1000000;
    _lastMs = nowMs;
    final t = truth?.call();
    _watch(_va, botA, nowMs, dtNs, t);
    _watch(_vb, botB, nowMs, dtNs, t);
    _compare(nowMs);
  }

  void _fail(int nowMs, Phone p, String what) {
    violations.add('t=${(nowMs / 1000).toStringAsFixed(2)}s ${p.name}: $what');
  }

  void _watch(_View v, Bot bot, int nowMs, int dtNs, Truth? t) {
    final p = v.phone;
    final s = p.session;
    final snap = s.play;
    if (snap == null) return;
    final status = s.statusLine;
    final modal = s.activity();
    final mine = s.remainingNs(p.side);
    final theirs = s.remainingNs(p.them);

    // Clocks are only on screen while the match is being played.
    if (snap.live || snap.waiting) {
      // My clock only ever counts down.
      final before = v.mineNs;
      if (before != null && mine > before) {
        ownClockUps.add(mine - before);
        _fail(nowMs, p, 'own clock went up ${_ms(mine - before)} ms');
      }
      v.mineNs = mine;

      // Their clock: a step up is a rewind; a drop beyond the time that
      // passed is a skip.
      final theirsBefore = v.theirsNs;
      if (theirsBefore != null) {
        if (theirs > theirsBefore) {
          oppRewinds.add(theirs - theirsBefore);
        } else if (theirsBefore - theirs > dtNs + 20 * 1000000) {
          oppSkips.add(theirsBefore - theirs - dtNs);
        }
      }
      v.theirsNs = theirs;
    } else {
      v.mineNs = null;
      v.theirsNs = null;
    }

    final tap = bot.last;
    if (tap != null && tap.settledAtMs == null) {
      if (s.pending != null) {
        // From the tap until the chain shows the move, the turn is not
        // ours and the overlay hides the wait.
        if (status == 'Your turn') _fail(nowMs, p, '"Your turn" after tapping');
        if (modal == null) {
          _fail(nowMs, p, 'no overlay while a move is in flight');
        } else if (tap.attack && modal.title != 'Battle!') {
          _fail(nowMs, p, 'attack in flight under "${modal.title}"');
        }
        if (mine != tap.faceNs) {
          _fail(nowMs, p, 'clock moved after the tap by ${_ms(mine - tap.faceNs)} ms');
        }
      } else {
        tap.settledAtMs = nowMs;
        tap.landed = snap.nonceOf(p.side) > tap.nonce;
        tapToSettledMs.add(nowMs - tap.atMs);
        if (tap.landed) {
          tap.bankAfterNs = snap.bankNs(p.side);
          faceVsBankNs.add(snap.bankNs(p.side) - tap.faceNs);
          // The overlay must not drop on a fight that is still open. (A
          // fight cannot be over already: that needs our own report.)
          if (tap.attack &&
              snap.nonceOf(p.side) == tap.nonce + 1 &&
              snap.nonceOf(p.them) == tap.oppNonce &&
              !snap.waiting &&
              snap.state != 'Ended') {
            _fail(nowMs, p, 'battle overlay dropped before the fight was shown');
          }
        }
      }
    }
    // After a move that landed, "Your turn" may only return once the
    // opponent has moved.
    if (tap != null &&
        tap.landed &&
        status == 'Your turn' &&
        snap.nonceOf(p.them) <= tap.oppNonce) {
      _fail(nowMs, p, '"Your turn" before the opponent moved');
    }

    // A fight keeps "Battle!" up from first sight until it is resolved.
    if (snap.waiting && s.waitingIsFight()) {
      v.inFight = true;
      if (modal?.title != 'Battle!') {
        _fail(nowMs, p, 'fight open under "${modal?.title}"');
      }
    } else if (snap.waiting) {
      if (modal == null) _fail(nowMs, p, 'arrival open with no overlay');
    } else {
      v.inFight = false;
    }

    if (t != null && !t.ended) {
      // What the screen claims must be true on chain.
      if (status == 'Your turn' && t.runningSide != p.side) {
        _fail(nowMs, p, '"Your turn" but the chain says "${t.runningSide}"');
      }
      // How long the chain's turn took to reach this screen.
      if (t.runningSide == p.side) {
        if (v.turnKey != t.turnStartedAtNs) {
          v.turnKey = t.turnStartedAtNs;
          v.sawTurn = false;
        }
        if (!v.sawTurn && status == 'Your turn') {
          v.sawTurn = true;
          noticeMs.add((t.nowNs - t.turnStartedAtNs) ~/ 1000000);
        }
      }
    }
  }

  void _compare(int nowMs) {
    final sa = a.session;
    final sb = b.session;
    final ra = sa.play;
    final rb = sb.play;
    if (ra == null || rb == null) return;

    final bothWaiting =
        sa.statusLine == "Opponent's turn" && sb.statusLine == "Opponent's turn";
    if (bothWaiting) {
      if (_bothSince < 0) _bothSince = nowMs;
    } else if (_bothSince >= 0) {
      bothWaitingMs.add(nowMs - _bothSince);
      _bothSince = -1;
    }

    final sameTurn =
        ra.nonceA == rb.nonceA &&
        ra.nonceB == rb.nonceB &&
        ra.state == rb.state &&
        ra.turnStartedAtNs == rb.turnStartedAtNs;
    if (!sameTurn || sa.pending != null || sb.pending != null) return;
    if (!(ra.live || ra.waiting)) return;
    for (final side in const ['A', 'B']) {
      final gap = (sa.remainingNs(side) - sb.remainingNs(side)).abs();
      if (ra.ticking && ra.toMove == side) {
        runningDisagreementNs = max(runningDisagreementNs, gap);
      } else {
        restDisagreementNs = max(restDisagreementNs, gap);
      }
    }
  }

  /// Closes any open measurement window at the end of a run.
  void finish(int nowMs) {
    if (_bothSince >= 0) {
      bothWaitingMs.add(nowMs - _bothSince);
      _bothSince = -1;
    }
  }

  static int _ms(int ns) => (ns / 1000000).round();

  static String _dist(List<int> xs, {int scale = 1, String unit = 'ms'}) {
    if (xs.isEmpty) return 'none';
    final s = [...xs]..sort();
    String at(double q) => (s[min(s.length - 1, (s.length * q).floor())] / scale).round().toString();
    return 'n=${s.length} p50=${at(0.5)} p90=${at(0.9)} max=${(s.last / scale).round()} $unit';
  }

  /// A plain-text summary of everything measured.
  String report(String title) {
    const m = 1000000;
    final landed = [...botA.taps, ...botB.taps].where((t) => t.landed).length;
    final failed = [...botA.taps, ...botB.taps].where((t) => t.settledAtMs != null && !t.landed).length;
    final visibleRewinds = oppRewinds.where((r) => r >= 250 * m).toList();
    return [
      '--- $title ---',
      'moves landed: $landed (attacks: ${[...botA.taps, ...botB.taps].where((t) => t.landed && t.attack).length}), taps refused or lost: $failed, samples: $samples',
      'violations: ${violations.length}',
      'own clock stepped up: ${ownClockUps.length} times',
      'tap -> overlay down: ${_dist(tapToSettledMs)}',
      'bank after move minus face at tap: ${_dist([for (final d in faceVsBankNs) d.abs()], scale: m)} (0 = clock did not move)',
      'opponent clock rewinds (any size): ${_dist(oppRewinds, scale: m)}',
      'opponent clock rewinds >= 250 ms: ${_dist(visibleRewinds, scale: m)}',
      'opponent clock forward skips: ${_dist(oppSkips, scale: m)}',
      'same running clock, phone vs phone: max ${_ms(runningDisagreementNs)} ms',
      'same resting clock, phone vs phone: max ${_ms(restDisagreementNs)} ms',
      'both screens "Opponent\'s turn": ${_dist(bothWaitingMs)}',
      if (truth != null) 'turn start on chain -> "Your turn" on screen: ${_dist(noticeMs)}',
      'errors shown: ${a.name}=${a.errors.length} ${b.name}=${b.errors.length}',
      for (final e in {...a.errors, ...b.errors}) '    "$e"',
      'opponent taps learned from the mailbox first: ${a.name}=${a.session.tapNotesUsed} ${b.name}=${b.session.tapNotesUsed}',
      'stale rows dropped: ${a.name}=${a.session.staleDropped} ${b.name}=${b.session.staleDropped}',
      'opponent-clock delay now: ${a.name}=${_ms(a.session.streamDelayNs)} ms ${b.name}=${_ms(b.session.streamDelayNs)} ms',
    ].join('\n');
  }
}

import 'dart:async';
import 'dart:math';

import 'package:engkwentro/mailbox.dart';
import 'package:engkwentro/near.dart';

/// One second in nanoseconds.
const sec = 1000 * 1000 * 1000;

/// Network conditions for one phone. Every draw comes from [seed].
class NetProfile {
  /// Defaults model what was measured against FastNEAR from this machine:
  /// a view round trip of roughly 0.3 to 0.45 s.
  NetProfile({
    required int seed,
    this.minLegMs = 140,
    this.maxLegMs = 220,
    this.lagChance = 0.1,
    this.maxLagBlocks = 1,
    this.viewHangChance = 0,
    this.viewFailChance = 0,
    this.txLostReplyChance = 0,
    this.txDroppedChance = 0,
    this.mailboxMinMs = 15,
    this.mailboxMaxMs = 60,
    this.mailboxHangChance = 0,
  }) : rng = Random(seed);

  /// A bad connection: slow and jittery, nodes that answer from old blocks,
  /// requests that hang until their deadline, replies and transactions lost.
  factory NetProfile.rough(int seed) => NetProfile(
    seed: seed,
    minLegMs: 150,
    maxLegMs: 900,
    lagChance: 0.35,
    maxLagBlocks: 4,
    viewHangChance: 0.04,
    viewFailChance: 0.03,
    txLostReplyChance: 0.06,
    txDroppedChance: 0.04,
    mailboxMinMs: 30,
    mailboxMaxMs: 700,
    mailboxHangChance: 0.03,
  );

  /// Source of every random draw for this phone's network.
  final Random rng;

  /// Fastest one-way trip to an RPC node (ms).
  final int minLegMs;

  /// Slowest one-way trip to an RPC node (ms).
  final int maxLegMs;

  /// Chance a view is answered by a node that is behind the tip.
  final double lagChance;

  /// How far behind such a node can be.
  final int maxLagBlocks;

  /// Chance a view stalls until the client's read deadline, then is retried.
  final double viewHangChance;

  /// Chance a view fails outright after its deadline.
  final double viewFailChance;

  /// Chance a transaction lands but its reply is lost.
  final double txLostReplyChance;

  /// Chance a transaction never reaches a block.
  final double txDroppedChance;

  /// Fastest mailbox round trip (ms).
  final int mailboxMinMs;

  /// Slowest mailbox round trip (ms).
  final int mailboxMaxMs;

  /// Chance a mailbox call stalls until its deadline and fails.
  final double mailboxHangChance;

  /// One trip to or from an RPC node.
  Duration leg() =>
      Duration(milliseconds: minLegMs + rng.nextInt(maxLegMs - minLegMs + 1));

  /// One mailbox round trip.
  Duration mailboxTrip() => Duration(
    milliseconds: mailboxMinMs + rng.nextInt(mailboxMaxMs - mailboxMinMs + 1),
  );

  /// Whether an event with probability [chance] happens this time.
  bool roll(double chance) => chance > 0 && rng.nextDouble() < chance;
}

/// What the chain did with one move, for measuring the clocks afterwards.
class MoveRecord {
  /// Filled in by [FakeChain] when `apply_moves` executes.
  MoveRecord({
    required this.side,
    required this.nonce,
    required this.turnStartedAtNs,
    required this.executedAtNs,
    required this.claimedThinkNs,
    required this.chargedNs,
    required this.bankAfterNs,
    required this.attack,
  });

  /// `"A"` or `"B"`.
  final String side;

  /// The mover's match nonce.
  final int nonce;

  /// Chain time the turn began.
  final int turnStartedAtNs;

  /// Chain time the move was executed.
  final int executedAtNs;

  /// `think_ns` as sent, or null.
  final int? claimedThinkNs;

  /// What was taken from the mover's bank.
  final int chargedNs;

  /// The mover's bank after the charge.
  final int bankAfterNs;

  /// True when the move opened a fight.
  final bool attack;

  /// Block-to-block length of the turn.
  int get turnNs => executedAtNs - turnStartedAtNs;
}

class _Match {
  String creator = '';
  String opponent = '';
  bool accepted = false;
  String first = '';
  String state = 'Created';
  String toMove = '';
  int nonceA = 0;
  int nonceB = 0;
  int waitFrom = 255;
  int waitTo = 255;
  int bankA = 0;
  int bankB = 0;
  int turnStartedAt = 0;
  bool paused = true;
  List<int> occ = List<int>.filled(72, 0);
  List<List<int>>? setupA;
  List<List<int>>? setupB;
  String? waitingMover;
  String? pendingBy;
  String? pendingExchange;
  bool pendingFlag = false;

  /// Landing square while [state] is `Breakthrough`, else null.
  int? breakthroughAt;

  /// Who arrived, while in `Breakthrough`.
  String? breakthroughBy;
  List<String> outcome = const [];
  String? settlement;
  bool flippedA = false;
  bool flippedB = false;

  /// Per-player stake in yocto as a decimal string (`0` = free).
  String stake = '0';
  bool paid = false;
  final List<int> opened = List<int>.filled(43, 255);
  final List<String> history = [];
}

/// A model of the match contract on a chain with real block timing.
///
/// Mirrors `contracts/engkwentro` for the calls a phone makes during play:
/// same state machine, same clock arithmetic (`think_ns`, the lag cap, the
/// flag window), same panic strings. Blocks come every [blockMs]. A
/// transaction is included in the block after it arrives and its effect is
/// visible one block later, as on NEAR. A view can be answered from an older
/// block, so stale replies exist here exactly as they do in the wild.
class FakeChain {
  /// [elapsed] is the simulation clock. Nothing here reads real time.
  FakeChain({required this.elapsed, this.blockMs = 600, int seed = 1})
    : _rng = Random(seed);

  /// Virtual time since the simulation began.
  final Duration Function() elapsed;

  /// Block interval.
  final int blockMs;

  final Random _rng;

  static const _genesisNs = 1794000000 * sec;
  static const _baseHeight = 250000000;
  static const _lagCapNs = 5 * sec;
  static const _key = 'ABCDEFGHJKLM';
  static const _open = 'open.engkwentro.testnet';

  final _Match _m = _Match();
  bool _exists = false;
  final List<(int, List<dynamic>)> _history = [];

  /// Every executed move, oldest first.
  final List<MoveRecord> moves = [];

  /// Transactions executed, by method.
  final Map<String, int> executed = {};

  /// Transactions that panicked, by method.
  final Map<String, int> refused = {};

  /// Height of the newest block.
  int get height => _baseHeight + elapsed().inMilliseconds ~/ blockMs;

  /// Timestamp of block [h].
  int timeOf(int h) => _genesisNs + (h - _baseHeight) * blockMs * 1000000;

  /// Chain time right now, between blocks.
  int get nowNs => _genesisNs + elapsed().inMicroseconds * 1000;

  /// `"A"`/`"B"` when a clock is running on chain right now, else `""`.
  String get runningSide => _live && !_m.paused ? _m.toMove : '';

  /// Match state right now.
  String get state => _m.state;

  /// Stored bank for [side] right now.
  int bankOf(String side) => side == 'A' ? _m.bankA : _m.bankB;

  /// Chain time the current turn began.
  int get turnStartedAtNs => _m.turnStartedAt;

  /// Occupancy right now. Tests may read it; use [edit] to change it.
  List<int> get occupancy => List<int>.unmodifiable(_m.occ);

  /// Rewrites the board in place, as if by a long sequence of moves.
  void edit(void Function(List<int> occ) change) {
    change(_m.occ);
    _snapshot(height);
  }

  bool get _live =>
      _m.state == 'Committed' ||
      _m.state == 'InProgress' ||
      _m.state == 'Breakthrough';

  /// Runs [method] as [caller] once it has made it into a block.
  ///
  /// Completes when the effect is visible, with the return value, or with
  /// the panic the client would see. No network delay is added here.
  Future<Object?> execute(
    String caller,
    String method,
    Map<String, dynamic> args,
  ) {
    final at = height + 2;
    final wait = Duration(microseconds: (timeOf(at) - nowNs) ~/ 1000);
    return Future<Object?>.delayed(wait, () {
      try {
        final out = _apply(caller, method, args, timeOf(at));
        executed[method] = (executed[method] ?? 0) + 1;
        _snapshot(at);
        return out;
      } on _Panic catch (p) {
        refused[method] = (refused[method] ?? 0) + 1;
        throw StateError(
          'tx failed: {ActionError: {kind: {FunctionCallError: '
          '{ExecutionError: Smart contract panicked: ${p.text}}}}}',
        );
      }
    });
  }

  /// Answers a view from the state as of block [atHeight].
  Object? view(String method, Map<String, dynamic> args, int atHeight) {
    if (!_exists) return null;
    switch (method) {
      case 'get_sync':
        List<dynamic>? row;
        for (final (h, r) in _history) {
          if (h > atHeight) break;
          row = r;
        }
        if (row == null) return null;
        final clocks = [...row[1] as List<dynamic>];
        clocks[3] = timeOf(atHeight);
        clocks[5] = atHeight;
        return [row[0], clocks, row[2], row[3]];
      case 'get_outcome':
        return _m.outcome.isEmpty ? null : _m.outcome;
      case 'get_settlement':
        return _m.settlement;
      case 'get_opened':
        return [..._m.opened];
      case 'get_join_key':
        return _key;
      case 'get_match_id_by_key':
        return 1;
      case 'get_match':
        return [_m.creator, _m.opponent, _m.accepted, _m.stake, _m.first];
    }
    throw StateError('FakeChain has no view $method');
  }

  void _snapshot(int h) {
    _history.add((
      h,
      [
        [_m.state, _m.toMove, _m.nonceA, _m.nonceB, _m.waitFrom, _m.waitTo],
        [_m.bankA, _m.bankB, _m.turnStartedAt, 0, _m.paused, 0],
        [
          _m.creator,
          _m.opponent,
          _m.accepted,
          _m.first,
          _m.setupA != null,
          _m.setupB != null,
        ],
        [..._m.occ],
      ],
    ));
  }

  String? _sideOf(String account) => account == _m.creator
      ? 'A'
      : account == _m.opponent
      ? 'B'
      : null;

  static String _other(String side) => side == 'A' ? 'B' : 'A';

  static String? _owner(int cell) => cell == 0
      ? null
      : cell <= 21
      ? 'A'
      : 'B';

  static bool _step(int from, int to) {
    if (from == to || from < 0 || to < 0 || from > 71 || to > 71) return false;
    final df = (from % 9 - to % 9).abs();
    final dr = (from ~/ 9 - to ~/ 9).abs();
    return (df == 1 && dr == 0) || (df == 0 && dr == 1);
  }

  bool _legal(String side, int from, int to) =>
      _step(from, to) &&
      _owner(_m.occ[from]) == side &&
      _owner(_m.occ[to]) != side;

  bool _hasMove(String side) {
    for (var from = 0; from < 72; from++) {
      if (_owner(_m.occ[from]) != side) continue;
      for (final to in [from - 1, from + 1, from - 9, from + 9]) {
        if (_legal(side, from, to)) return true;
      }
    }
    return false;
  }

  static bool _enemyHome(String side, int sq) =>
      sq ~/ 9 == (side == 'A' ? 7 : 0);

  void _end(List<String> outcome) {
    _m.state = 'Ended';
    _m.outcome = outcome;
    _m.settlement = 'AwaitingFlip';
    _m.paused = true;
    _m.toMove = '';
  }

  void _enterWait(int from, int to, String mover) {
    _m.state = 'WaitingForArbiter';
    _m.waitFrom = from;
    _m.waitTo = to;
    _m.waitingMover = mover;
    _m.paused = true;
    _m.pendingBy = null;
    _m.pendingExchange = null;
    _m.pendingFlag = false;
  }

  void _leaveWait() {
    _m.waitFrom = 255;
    _m.waitTo = 255;
    _m.waitingMover = null;
  }

  bool _repeats(String incoming) {
    final key = '${_m.occ.join(',')}|$incoming';
    final seen = _m.history.where((k) => k == key).length + 1;
    _m.history.add(key);
    if (seen >= 3) {
      _end(const ['Draw', '', 'Repetition']);
      return true;
    }
    return false;
  }

  void _finishTurn(String mover, int now) {
    final incoming = _other(mover);
    if (!_hasMove(incoming)) {
      final reason = _m.state == 'Breakthrough'
          ? 'FlagBreakthrough'
          : 'Immobilised';
      _m.breakthroughAt = null;
      _m.breakthroughBy = null;
      _end(['Win', mover, reason]);
      return;
    }
    _m.toMove = incoming;
    _m.turnStartedAt = now;
    _m.paused = false;
    _m.state = 'InProgress';
  }

  Object? _apply(
    String caller,
    String method,
    Map<String, dynamic> args,
    int now,
  ) {
    switch (method) {
      case 'create_match':
        _exists = true;
        _m.creator = caller;
        _m.opponent = (args['opponent'] as String?) ?? _open;
        _m.stake = (args['stake'] ?? '0').toString();
        final bank = (args['clock_minutes'] as int) * 60 * sec;
        _m.bankA = bank;
        _m.bankB = bank;
        return [1, _key];
      case 'accept_match':
      case 'accept_match_by_key':
        if (_m.accepted) throw _Panic('match already accepted');
        if (_m.opponent != _open && _m.opponent != caller) {
          throw _Panic('caller is not a player in this match');
        }
        // Deposit is checked by FakeNearClient via [lastDepositYocto] if set;
        // free matches stay open without one.
        _m.opponent = caller;
        _m.accepted = true;
        _m.first = _rng.nextBool() ? 'A' : 'B';
        return method == 'accept_match' ? null : 1;
      case 'claim_payout':
        if (_m.settlement != 'Settled' &&
            _m.settlement != 'Forfeited' &&
            _m.settlement != 'Voided') {
          throw _Panic('illegal source state');
        }
        if (_m.paid) throw _Panic('already paid');
        _m.paid = true;
        return null;
      case 'commit_setup':
        if (_m.state != 'Created') throw _Panic('illegal source state');
        if (!_m.accepted) throw _Panic('opponent has not accepted');
        final side = _sideOf(caller);
        if (side == null) throw _Panic('caller is not a player in this match');
        if ((side == 'A' ? _m.setupA : _m.setupB) != null) {
          throw _Panic('setup already committed');
        }
        final squares = [
          for (final p in args['placements'] as List)
            [(p as List)[0] as int, p[1] as int],
        ];
        if (side == 'A') {
          _m.setupA = squares;
        } else {
          _m.setupB = squares;
        }
        return null;
      case 'confirm_roster':
        if (_sideOf(caller) == null) {
          throw _Panic('caller is not a player in this match');
        }
        if (_m.state != 'Created' || !_m.accepted) {
          throw _Panic('illegal source state');
        }
        if (_m.setupA == null || _m.setupB == null) {
          throw _Panic('both setups are required');
        }
        for (var i = 0; i < 21; i++) {
          _m.occ[_m.setupA![i][0] + _m.setupA![i][1] * 9] = i + 1;
          _m.occ[_m.setupB![i][0] + _m.setupB![i][1] * 9] = i + 22;
        }
        _m.toMove = _m.first;
        _m.state = 'Committed';
        _m.turnStartedAt = now;
        _m.paused = false;
        return null;
      case 'apply_moves':
        _applyMove(caller, args, now);
        return null;
      case 'resolve_challenge':
        _report(
          caller,
          args['exchange'] as String,
          args['flag_captured'] as bool,
          now,
        );
        return null;
      case 'confirm_arrival':
        _report(caller, null, args['is_flag'] as bool, now);
        return null;
      case 'claim_timeout':
        if (_m.paused || _m.state == 'WaitingForArbiter' || _m.toMove.isEmpty) {
          throw _Panic('illegal source state');
        }
        final side = _m.toMove;
        if (now - _m.turnStartedAt < bankOf(side) + _lagCapNs) {
          throw _Panic('illegal source state');
        }
        _end(['Win', _other(side), 'Timeout']);
        return null;
      case 'resign':
        final side = _sideOf(caller);
        if (side == null) throw _Panic('caller is not a player in this match');
        if (!_live) throw _Panic('illegal source state');
        _end(['Win', _other(side), 'Resignation']);
        return null;
      case 'submit_setup':
        if (_m.state != 'Ended') throw _Panic('match has not ended');
        final side = _sideOf(caller);
        if (side == null) throw _Panic('caller is not a player in this match');
        final pieces = args['pieces'] as List;
        for (var i = 0; i < pieces.length; i++) {
          _m.opened[(side == 'A' ? 1 : 22) + i] = i % 15;
        }
        if (side == 'A') {
          _m.flippedA = true;
        } else {
          _m.flippedB = true;
        }
        return null;
      case 'settle':
        if (_m.settlement != 'AwaitingFlip') {
          throw _Panic('illegal source state');
        }
        if (!_m.flippedA || !_m.flippedB) {
          throw _Panic('both sides have not been verified');
        }
        _m.settlement = 'Settled';
        return null;
    }
    throw StateError('FakeChain has no method $method');
  }

  void _applyMove(String caller, Map<String, dynamic> args, int now) {
    if (_m.state == 'Ended' ||
        _m.state == 'WaitingForArbiter' ||
        _m.toMove.isEmpty) {
      throw _Panic('illegal source state');
    }
    final side = _m.toMove;
    if (_sideOf(caller) != side) throw _Panic('NEP-413 signature rejected');
    final mv = (args['moves'] as List).single as Map<String, dynamic>;
    final from = mv['from'] as int;
    final to = mv['to'] as int;
    final expected = side == 'A' ? _m.nonceA : _m.nonceB;
    if (mv['nonce'] != expected) throw _Panic('unexpected move nonce');
    if (!_live) throw _Panic('illegal source state');

    // play::charge_until + play::charge_clock.
    final raw = args['think_ns'];
    final claim = raw == null ? null : int.parse(raw as String);
    final elapsed = _m.turnStartedAt == 0 ? 0 : max(0, now - _m.turnStartedAt);
    final int charged = claim == null
        ? elapsed
        : min(max(claim, max(0, elapsed - _lagCapNs)), elapsed);
    final bank = bankOf(side);
    final flagged = charged >= bank;
    final attack = !flagged && _owner(_m.occ[to]) == _other(side);

    // In apply_one an illegal move panics after the nonce and the clock
    // were touched, which rolls both back. Same result: refuse first.
    if (!flagged && !_legal(side, from, to)) throw _Panic('illegal move');
    if (side == 'A') {
      _m.nonceA = expected + 1;
      _m.bankA = flagged ? 0 : bank - charged;
    } else {
      _m.nonceB = expected + 1;
      _m.bankB = flagged ? 0 : bank - charged;
    }
    moves.add(
      MoveRecord(
        side: side,
        nonce: expected,
        turnStartedAtNs: _m.turnStartedAt,
        executedAtNs: now,
        claimedThinkNs: claim,
        chargedNs: flagged ? bank : charged,
        bankAfterNs: bankOf(side),
        attack: attack,
      ),
    );
    if (flagged) {
      _end(['Win', _other(side), 'Timeout']);
      return;
    }
    // Silent breakthrough reply: challenge the Flag square, or lose.
    if (_m.state == 'Breakthrough') {
      final at = _m.breakthroughAt!;
      final by = _m.breakthroughBy!;
      if (to == at && _owner(_m.occ[at]) == by) {
        _enterWait(from, to, side);
        return;
      }
      _m.breakthroughAt = null;
      _m.breakthroughBy = null;
      _end(['Win', by, 'FlagBreakthrough']);
      return;
    }
    if (attack) {
      _enterWait(from, to, side);
      return;
    }
    _m.occ[to] = _m.occ[from];
    _m.occ[from] = 0;
    if (_enemyHome(side, to)) {
      _enterWait(from, to, side);
      return;
    }
    _m.state = 'InProgress';
    if (_repeats(_other(side))) return;
    _finishTurn(side, now);
  }

  void _report(String caller, String? exchange, bool flag, int now) {
    final side = _sideOf(caller);
    if (side == null) throw _Panic('caller is not a player in this match');
    if (_m.state != 'WaitingForArbiter') throw _Panic('illegal source state');
    final from = _m.waitFrom;
    final to = _m.waitTo;
    final mover = _m.waitingMover!;
    final holder = _owner(_m.occ[to]);
    final fight = holder != null && holder != mover;
    if (fight != (exchange != null)) throw _Panic('illegal source state');
    if (_m.pendingBy == null) {
      _m.pendingBy = side;
      _m.pendingExchange = exchange;
      _m.pendingFlag = flag;
      return;
    }
    if (_m.pendingBy == side) throw _Panic('illegal source state');
    if (_m.pendingExchange != exchange || _m.pendingFlag != flag) {
      _end(const ['Void', '', 'MutualSettlementFailure']);
      _m.settlement = 'Voided';
      return;
    }
    _m.pendingBy = null;
    if (exchange != null) {
      switch (exchange) {
        case 'AttackerWins':
          _m.occ[to] = _m.occ[from];
          _m.occ[from] = 0;
        case 'DefenderWins':
          _m.occ[from] = 0;
        default:
          _m.occ[from] = 0;
          _m.occ[to] = 0;
      }
      _m.history.clear();
      if (flag) {
        _leaveWait();
        _end(['Win', mover, 'FlagCaptured']);
        return;
      }
      if (_enemyHome(mover, to) && _owner(_m.occ[to]) == mover) {
        _enterWait(to, to, mover);
        return;
      }
    } else if (flag) {
      _leaveWait();
      _m.state = 'Breakthrough';
      _m.breakthroughBy = mover;
      _m.breakthroughAt = to;
      _m.toMove = _other(mover);
      _m.turnStartedAt = now;
      _m.paused = false;
      return;
    }
    _leaveWait();
    if (_repeats(_other(mover))) return;
    _finishTurn(mover, now);
  }
}

class _Panic implements Exception {
  _Panic(this.text);
  final String text;
}

/// A [NearClient] that talks to a [FakeChain] over a [NetProfile].
///
/// Reproduces what the real client does on a bad connection, as seen from
/// above it: a stalled read costs the read deadline and is retried once; a
/// transaction whose reply is lost is found again by hash; a transaction
/// that never lands ends in a `TimeoutException`.
class FakeNear extends NearClient {
  /// [account] signs; [net] decides how each call fares.
  FakeNear(this.chain, String account, this.net)
    : super(
        rpcUrl: 'http://fake',
        accountId: account,
        privateKey: 'ed25519:11111111111111111111111111111111',
        contractId: 'play.engkwentro.testnet',
      );

  /// The chain every phone shares.
  final FakeChain chain;

  /// This phone's connection.
  final NetProfile net;

  /// Views sent.
  int views = 0;

  /// Transactions sent.
  int calls = 0;

  /// Requests in flight right now, and the most ever at once.
  int inFlight = 0;

  /// Most requests ever in flight at once. One means strictly serial.
  int maxInFlight = 0;

  static const _readDeadline = Duration(seconds: 4);
  static const _commitDeadline = Duration(seconds: 10);

  @override
  Future<void> ready() async {}

  Future<T> _tracked<T>(Future<T> Function() body) async {
    inFlight++;
    maxInFlight = max(maxInFlight, inFlight);
    try {
      return await body();
    } finally {
      inFlight--;
    }
  }

  @override
  Future<dynamic> view(String method, [Object args = const {}]) =>
      _tracked(() async {
        views++;
        if (net.roll(net.viewFailChance)) {
          await Future<void>.delayed(_readDeadline * 2);
          throw TimeoutException('NEAR RPC query timed out');
        }
        if (net.roll(net.viewHangChance)) {
          await Future<void>.delayed(_readDeadline);
        }
        await Future<void>.delayed(net.leg());
        final lag = net.roll(net.lagChance)
            ? 1 + net.rng.nextInt(net.maxLagBlocks)
            : 0;
        final out = chain.view(
          method,
          args as Map<String, dynamic>,
          chain.height - lag,
        );
        await Future<void>.delayed(net.leg());
        return out;
      });

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Object args, {
    String depositYocto = '0',
    int gas = 100000000000000,
  }) => _tracked(() async {
    calls++;
    if (net.roll(net.txDroppedChance)) {
      // Commit deadline, then four fruitless look-ups by hash.
      await Future<void>.delayed(_commitDeadline + const Duration(seconds: 8));
      throw TimeoutException('NEAR did not confirm the transaction');
    }
    final lostReply = net.roll(net.txLostReplyChance);
    final sentAt = chain.elapsed();
    await Future<void>.delayed(net.leg());
    Object? decoded;
    Object? failure;
    try {
      decoded = await chain.execute(
        accountId,
        method,
        args as Map<String, dynamic>,
      );
    } catch (e) {
      failure = e;
    }
    if (lostReply) {
      // The reply never comes; the client waits out the deadline and then
      // finds the transaction by hash.
      final waited = chain.elapsed() - sentAt;
      if (waited < _commitDeadline) {
        await Future<void>.delayed(_commitDeadline - waited);
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    await Future<void>.delayed(net.leg());
    if (failure != null) throw failure;
    return {'decoded': decoded, 'tx_hash': 'fake'};
  });
}

/// An in-memory [Mailbox] with latency and the occasional stall.
class FakeMailbox extends Mailbox {
  /// All phones in a match share [store]; each has its own [net].
  FakeMailbox(this.store, this.net) : super('http://fake');

  /// Blobs by `matchId/key`.
  final Map<String, String> store;

  /// This phone's connection.
  final NetProfile net;

  Future<void> _trip() async {
    if (net.roll(net.mailboxHangChance)) {
      await Future<void>.delayed(const Duration(seconds: 5));
      throw TimeoutException('mailbox timed out');
    }
    await Future<void>.delayed(net.mailboxTrip());
  }

  @override
  Future<void> put(String matchId, String key, String blob) async {
    await _trip();
    store['$matchId/$key'] = blob;
  }

  @override
  Future<String?> get(String matchId, String key) async {
    await _trip();
    return store['$matchId/$key'];
  }
}

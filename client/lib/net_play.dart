import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'arbiter.g.dart';
import 'commit.dart';
import 'game.dart';
import 'join_key.dart';
import 'mailbox.dart';
import 'match_store.dart';
import 'near.dart';
import 'ot.dart';

/// Must match `play::LAG_CAP_NS` on the contract.
///
/// The contract charges a mover for the time the turn was on their screen,
/// but credits at most this much network time per move. It is also how long
/// a flag stays unclaimable after a bank reaches zero.
const int lagCapNs = 5 * 1000 * 1000 * 1000;

/// One `get_sync` row: turn, clocks, seats and setup flags from one block.
///
/// Everything the match screen paints comes from one of these. The turn in
/// the status line and the clock that ticks can therefore never disagree,
/// which the four separate views used before allowed.
class PlaySnap {
  /// Play fields are positional (as `get_play`); the rest are named.
  PlaySnap(
    this.state,
    this.toMove,
    this.nonceA,
    this.nonceB,
    this.waitFrom,
    this.waitTo, {
    this.bankANs = 0,
    this.bankBNs = 0,
    this.turnStartedAtNs = 0,
    this.chainNowNs = 0,
    this.paused = true,
    this.height = 0,
    this.setupA = false,
    this.setupB = false,
  });

  /// Parses the `(play, clocks, seats, occupancy)` tuple from `get_sync`.
  factory PlaySnap.fromSync(List<dynamic> raw) {
    final play = raw[0] as List<dynamic>;
    final clocks = raw[1] as List<dynamic>;
    final seats = raw[2] as List<dynamic>;
    return PlaySnap(
      play[0] as String,
      play[1] as String,
      asInt(play[2]),
      asInt(play[3]),
      asInt(play[4]),
      asInt(play[5]),
      bankANs: asInt(clocks[0]),
      bankBNs: asInt(clocks[1]),
      turnStartedAtNs: asInt(clocks[2]),
      chainNowNs: asInt(clocks[3]),
      paused: clocks[4] as bool,
      height: asInt(clocks[5]),
      setupA: seats.length > 4 && seats[4] == true,
      setupB: seats.length > 5 && seats[5] == true,
    );
  }

  /// `Created` / `Committed` / `InProgress` / `WaitingForArbiter` /
  /// `Breakthrough` / `Ended`.
  final String state;

  /// `"A"` or `"B"`, or `""` when nobody is to move.
  final String toMove;

  /// Next nonce Alice must put on `SignedMove`.
  final int nonceA;

  /// Next nonce Bob must put on `SignedMove`.
  final int nonceB;

  /// Attacker square while waiting, else unused.
  final int waitFrom;

  /// Defender / arrival square while waiting, else unused.
  final int waitTo;

  /// Alice's bank as stored: what she had when the current turn started.
  final int bankANs;

  /// Bob's bank as stored: what he had when the current turn started.
  final int bankBNs;

  /// Chain time when the current turn started (ns).
  final int turnStartedAtNs;

  /// Block timestamp this row was read at (ns).
  final int chainNowNs;

  /// True when the chain has the clocks stopped (fight, arrival, ended).
  final bool paused;

  /// Block height this row was read at. Orders rows from different nodes.
  final int height;

  /// True once Alice's sealed army is on chain.
  final bool setupA;

  /// True once Bob's sealed army is on chain.
  final bool setupB;

  /// True when both armies are locked and the match can start.
  bool get bothSetups => setupA && setupB;

  /// True when both sides must report a fight or arrival.
  bool get waiting => state == 'WaitingForArbiter';

  /// True while a move may be played.
  bool get live =>
      state == 'Committed' || state == 'InProgress' || state == 'Breakthrough';

  /// True when the side-to-move clock is running on chain.
  bool get ticking => live && !paused && toMove.isNotEmpty;

  /// Stored bank for `"A"` or `"B"`.
  int bankNs(String side) => side == 'A' ? bankANs : bankBNs;

  /// Next nonce for `"A"` or `"B"`.
  int nonceOf(String side) => side == 'A' ? nonceA : nonceB;

  /// NEAR JSON may return u64 as [int] or decimal [String].
  static int asInt(Object? v) {
    if (v is int) return v;
    if (v is String) return int.parse(v);
    throw FormatException('expected an integer, got $v');
  }
}

/// A move this phone has committed to but the chain has not shown yet.
///
/// Exists from the tap until a `get_sync` row shows this side's nonce
/// advanced (or the transaction fails). While it exists the phone is not
/// "to move": the modal is up, the board is locked, and this side's clock
/// holds at [faceNs], which is what the contract leaves in the bank when it
/// honours [thinkNs].
class PendingMove {
  /// Captured synchronously at the tap.
  PendingMove({
    required this.from,
    required this.to,
    required this.nonce,
    required this.attack,
    required this.thinkNs,
    required this.faceNs,
    required this.tappedMonoNs,
  });

  /// Source square.
  final int from;

  /// Destination square.
  final int to;

  /// Nonce the move is signed with. Confirmed once the chain's is higher.
  final int nonce;

  /// True when the destination held an enemy piece: this move is a battle.
  final bool attack;

  /// How long the turn was on this screen before the tap, sent as `think_ns`.
  final int thinkNs;

  /// This side's remaining bank at the tap (ns).
  final int faceNs;

  /// Monotonic time of the tap.
  final int tappedMonoNs;

  /// True once `apply_moves` succeeded and only a view is outstanding.
  bool sent = false;
}

/// `m:ss` or `h:mm:ss`, floored to whole seconds, never negative.
String formatClock(Duration left) {
  final total = left.isNegative ? 0 : left.inSeconds;
  final m = total ~/ 60;
  final s = total % 60;
  if (m >= 60) {
    final h = m ~/ 60;
    final mm = m % 60;
    return '$h:${mm.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

final Stopwatch _monotonic = Stopwatch()..start();

/// Nanoseconds on a clock that never jumps, unlike wall time.
int _monotonicNs() => _monotonic.elapsedMicroseconds * 1000;

/// One phone's handle on a testnet match: NEAR calls plus OT mailbox.
class NetSession {
  /// [sideA] true is Alice (`player1`). [opponent] is the named challengee.
  ///
  /// [monoNs] is a monotonic nanosecond clock; tests inject a virtual one.
  NetSession({
    required this.near,
    required this.mailbox,
    required this.sideA,
    required this.opponent,
    int Function()? monoNs,
  }) : monoNs = monoNs ?? _monotonicNs;

  /// Signer for this phone.
  final NearClient near;

  /// OT blob store.
  final Mailbox mailbox;

  /// Monotonic nanoseconds. Never wall time: that can jump mid-match.
  final int Function() monoNs;

  /// Called whenever something the screen paints has changed.
  void Function()? onChange;

  void _changed() => onChange?.call();

  /// Whether this phone is player A (creator). Set again on [resume].
  bool sideA;

  /// The other account id, used at `create_match`.
  String opponent;

  /// Sequential audit id. Not shown as the shareable key.
  int? matchId;

  /// 12-character join key. Players share this, not [matchId].
  String? joinKey;

  /// Per-player stake in yoctoNEAR (`0` = free). From `create_match` / `get_match`.
  String stakeYocto = '0';

  /// True after a successful `claim_payout` (or free match with nothing to claim).
  bool payoutClaimed = false;

  /// Local ranks, filled at [commitArmy].
  late List<Rank> ranks;

  /// Per-piece 32-byte salts, filled at [commitArmy].
  late List<Uint8List> salts;

  /// Home squares matching [ranks], filled at [commitArmy].
  late List<(int, int)> squares;

  /// True after [commitArmy] succeeds. Needed to flip.
  bool rosterReady = false;

  /// Pending setup placements by wire square, before [commitArmy].
  final Map<int, Rank> setup = {};

  /// Rank currently lifted from the setup tray, if any.
  Rank? setupSelected;

  /// True while this phone still has to arrange and commit its army.
  bool get settingUp => accepted && matchId != null && !rosterReady;

  /// True while the local setup map should stand in for on-chain occupancy.
  ///
  /// `get_board_for` stays empty until `confirm_roster`, so keep painting the
  /// committed army locally during the gap.
  bool get showSetupBoard =>
      setup.isNotEmpty &&
      (!rosterReady || occupancy.every((occupied) => occupied == 0));

  /// Pieces still waiting in the setup tray.
  int get setupRemaining => 21 - setup.length;

  /// Remaining copies of [rank] in the setup tray.
  int setupCount(Rank rank) =>
      (composition[rank] ?? 0) -
      setup.values.where((placed) => placed == rank).length;

  /// Whether [square] is inside this phone's three home rows.
  bool setupHome(int square) {
    final rank = MatchGame.rankOf(square);
    return sideA
        ? MatchGame.homeA.contains(rank)
        : MatchGame.homeB.contains(rank);
  }

  /// Rank staged on [square] during setup, or null.
  Rank? setupRankAt(int square) => setup[square];

  /// Selects [rank] so the next home-square tap places it.
  void selectSetupRank(Rank rank) {
    if (setupCount(rank) <= 0) return;
    setupSelected = rank;
  }

  /// Places the selected rank, or lifts a placed piece back to the tray.
  void setupTap(int square) {
    if (rosterReady || !setupHome(square)) return;
    final placed = setup.remove(square);
    if (placed != null) {
      setupSelected = placed;
      return;
    }
    final rank = setupSelected;
    if (rank == null || setupCount(rank) <= 0) return;
    setup[square] = rank;
    if (setupCount(rank) <= 0) setupSelected = null;
  }

  /// Fills the default 21-piece layout so the player can rearrange it.
  void setupAutoFill() {
    if (rosterReady) return;
    setup.clear();
    final defaultRanks = defaultRoster();
    final defaultSquares = homeSquares(sideA);
    for (var i = 0; i < defaultRanks.length; i++) {
      final (file, boardRank) = defaultSquares[i];
      setup[MatchGame.sq(file, boardRank)] = defaultRanks[i];
    }
    setupSelected = null;
  }

  /// Empties the setup tray and lifts every staged piece.
  void setupClear() {
    if (rosterReady) return;
    setup.clear();
    setupSelected = null;
  }

  /// Piece-index → rank from `get_opened`. `255` is still hidden.
  List<int> opened = List<int>.filled(43, 255);

  /// `get_settlement` string, or null before `Ended`.
  String? settlement;

  bool _submittedSetup = false;
  bool _settleTried = false;

  /// 72 occupancy ints from `get_board_for`.
  List<int> occupancy = List<int>.filled(72, 0);

  /// Own piece indices removed from the board, in defeat order.
  final List<int> graveyardOcc = [];

  /// Latest applied `get_sync` row, or null before the first load.
  ///
  /// The only source for the turn, the clocks and the board. Replaced
  /// whole; never patched field by field.
  PlaySnap? play;

  /// A move tapped on this phone that the chain has not shown yet.
  PendingMove? pending;

  /// False in headless runs, where there is no key-value store to write to.
  bool persist = true;

  /// Largest `chain time − monotonic time` seen on any row.
  ///
  /// Every row is a little old when it arrives, so each one gives a lower
  /// bound on the true offset and the largest is the best estimate. Because
  /// it only grows, a clock derived from it only moves forward.
  int? _chainOffsetNs;

  /// Rows discarded because a newer block had already been applied.
  int staleDropped = 0;

  /// The turn (by its chain start time) this phone is currently timing.
  int? _turnSeenKey;

  /// Monotonic time this phone first showed the turn in [_turnSeenKey].
  int? _turnSeenMonoNs;

  /// How far behind the opponent's running clock is drawn. See
  /// [_measureStreamDelay].
  int _streamDelayNs = _streamDelayStartNs;

  /// Recent tap-to-here lags, newest last.
  final List<int> _streamLags = [];

  /// The opponent's phone saying "I tapped, my clock reads this".
  ///
  /// Arrives through the mailbox a second or two before the move is in a
  /// block. Used to stop drawing their clock, and for nothing else: the
  /// turn, the board and the banks only ever come from the chain.
  ({int nonce, int faceNs, int atMonoNs})? _theirTap;

  /// Opponent taps learned from the mailbox before the chain. Diagnostics.
  int tapNotesUsed = 0;

  /// Whether tap notes are sent and read.
  ///
  /// With this off nothing about a clock travels through the mailbox: the
  /// opponent's clock keeps counting until the chain shows their move and
  /// is then corrected back, by about the time the move took to land.
  bool tapNotes = true;

  /// A tap note is dropped if the move has not landed this long after it.
  static const _tapNoteTtlNs = 10 * 1000 * 1000 * 1000;

  /// Opponent's phone saying "I can act on this turn now".
  ///
  /// Display only: until it arrives their clock face stays at the bank on
  /// this phone, so it does not burn while their board is still locked.
  ({int turnStartedAtNs, int atMonoNs})? _theirSeen;

  /// Turn-seen notes learned from the mailbox. Diagnostics.
  int turnSeenNotesUsed = 0;

  /// Square of a Flag that opened a silent breakthrough, if this phone
  /// knows it (mover, or after the win reveal).
  int? _flagAt;

  /// Occupancy index of that Flag, for the end-of-match reveal.
  int? _flagOcc;

  /// No `claim_timeout` before this monotonic time (after a refused claim).
  int _claimNotBeforeMonoNs = 0;

  /// A lower height this far back is a different chain, not a slow node.
  static const _staleHeightWindow = 600;

  /// How long an unconfirmed move is waited for after an unclear send.
  static const _confirmDeadlineNs = 8 * 1000 * 1000 * 1000;

  static const _streamDelayStartNs = 1500 * 1000 * 1000;
  static const _streamDelayMinNs = 300 * 1000 * 1000;
  static const _streamDelayMaxNs = 3000 * 1000 * 1000;

  /// Status line.
  String log = 'Connecting…';

  /// Set when the match has ended or this phone resigned.
  String? result;

  /// `"Win"` / `"Draw"` / `"Void"` from `get_outcome`, or null.
  String? outcomeKind;

  /// `"A"` / `"B"` when [outcomeKind] is `Win`.
  String? outcomeWinner;

  /// Wire reason label from `get_outcome` (e.g. `FlagCaptured`).
  String? outcomeReason;

  /// Selected square on the snug board.
  int? selected;

  /// True while a call is in flight; the UI disables buttons.
  bool busy = false;

  String? _progress;

  /// Short line for the progress overlay while a NEAR / fight step is in flight.
  String? get progress => _progress;

  set progress(String? value) {
    if (_progress == value) return;
    _progress = value;
    _changed();
  }

  final Map<String, OtOffer> _offers = {};
  final Set<String> _published = {};
  final Set<String> _sealed = {};
  final Set<String> _reported = {};

  /// This phone's NEAR account.
  String get me => near.accountId;

  /// `"A"` or `"B"`, matching [PlaySnap.toMove].
  String get sideLabel => sideA ? 'A' : 'B';

  /// First mover `"A"` / `"B"` after roster confirm. Light army = first.
  String? first;

  /// Whether the opponent has accepted. False while waiting on an open key.
  bool accepted = false;

  /// True when [sideAArmy] is the first mover (light pieces).
  ///
  /// [first] is set on-chain at accept (before setup). Until then both
  /// phones avoid a provisional colour so pieces do not swap at kickoff.
  bool armyIsLight(bool sideAArmy) {
    if (first == null) return sideAArmy; // unused for art until accept
    return sideAArmy == (first == 'A');
  }

  /// Light set for occupancy [occ] (1–21 A, 22–42 B).
  bool occIsLight(int occ) => armyIsLight(occ <= 21);

  /// Whether this phone paints with the light set.
  bool get iAmLight => armyIsLight(sideA);

  /// `create_match`. Omits [opponent] for an open challenge (anyone with the key).
  ///
  /// [stakeYocto] is attached as the deposit and stored on the match. Joiner
  /// must attach the same amount on accept.
  Future<void> create({int clockMinutes = 15, String stakeYocto = '0'}) async {
    progress = 'Creating match on NEAR…';
    this.stakeYocto = stakeYocto;
    final args = <String, dynamic>{
      'stake': stakeYocto,
      'ruleset': 'Standard',
      'clock_minutes': clockMinutes,
    };
    if (opponent.isNotEmpty && opponent != me) {
      args['opponent'] = opponent;
    }
    final raw = await near.call('create_match', args, depositYocto: stakeYocto);
    _readCreated(raw);
    accepted = false;
    sideA = true;
    log = 'Share ${formatJoinKey(joinKey ?? '')}. Waiting for opponent.';
    await _persistLocal();
    progress = null;
  }

  /// Parses `(match_id, join_key)` from `create_match`.
  void _readCreated(Map<String, dynamic> raw) {
    final decoded = raw['decoded'];
    if (decoded is List && decoded.length >= 2) {
      matchId = decoded[0] as int;
      joinKey = decoded[1] as String;
      return;
    }
    if (decoded is int) {
      matchId = decoded;
    }
  }

  /// `accept_match` for an existing sequential [id].
  ///
  /// Attaches [stakeYocto] (set by [create] / [resume] / [depositYocto]).
  Future<void> accept(int id, {String? depositYocto}) async {
    matchId = id;
    if (depositYocto != null) stakeYocto = depositYocto;
    await near.call('accept_match', {'match_id': id}, depositYocto: stakeYocto);
    joinKey ??= (await near.view('get_join_key', {'match_id': id})) as String?;
    accepted = true;
    sideA = false;
    log = 'Accepted ${formatJoinKey(joinKey ?? id.toString())}.';
    await _persistLocal();
  }

  /// Accepts via the shareable key (first join only).
  ///
  /// Attaches [stakeYocto]. [resume] loads stake from `get_match` first so
  /// this call does not add views on the join path.
  Future<void> acceptKey(String raw, {String? depositYocto}) async {
    final key = normalizeJoinKey(raw);
    if (!isJoinKey(key)) {
      throw FormatException('Enter the 12-character match key.');
    }
    if (depositYocto != null) stakeYocto = depositYocto;
    final res = await near.call('accept_match_by_key', {
      'join_key': key,
    }, depositYocto: stakeYocto);
    matchId = res['decoded'] as int? ?? matchId;
    joinKey = key;
    accepted = true;
    sideA = false;
    log = 'Joined ${formatJoinKey(key)}.';
    await _persistLocal();
  }

  /// Rejoins an existing match by 12-char key or numeric match id.
  ///
  /// Creator and bound opponent both attach via views. Calls `accept` only
  /// when the match is still open. Restores a sealed army from [MatchStore]
  /// when this device previously committed.
  Future<void> resume(String raw) async {
    progress = 'Rejoining match…';
    final trimmed = raw.trim();
    final key = normalizeJoinKey(trimmed);
    int? id;
    if (isJoinKey(key)) {
      id = await near.view('get_match_id_by_key', {'join_key': key}) as int?;
      joinKey = key;
    } else {
      id = int.tryParse(trimmed);
    }
    if (id == null) {
      throw FormatException(
        'Enter the 12-character match key or numeric match id.',
      );
    }
    matchId = id;
    joinKey ??= (await near.view('get_join_key', {'match_id': id})) as String?;

    final meta = await near.view('get_match', {'match_id': id});
    if (meta is! List || meta.length < 3) {
      throw StateError('Match $id not found on chain.');
    }
    final creator = meta[0] as String;
    final opp = meta[1] as String;
    final acceptedFlag = meta[2] as bool;
    if (meta.length >= 4) {
      stakeYocto = meta[3].toString();
    }
    if (meta.length >= 5) {
      final f = meta[4] as String;
      if (f == 'A' || f == 'B') first = f;
    }

    if (me == creator) {
      sideA = true;
      opponent = opp;
      accepted = acceptedFlag;
    } else if (me == opp || (!acceptedFlag && opp == openOpponentAccount)) {
      // Bound opponent, or first player claiming an open challenge.
      if (!acceptedFlag) {
        final acceptWith = joinKey ?? key;
        if (isJoinKey(normalizeJoinKey(acceptWith))) {
          await acceptKey(acceptWith, depositYocto: stakeYocto);
        } else {
          await accept(id, depositYocto: stakeYocto);
        }
        progress = null;
        return;
      }
      sideA = false;
      opponent = creator;
      accepted = true;
    } else {
      throw StateError('Signed in as $me, but this match is $creator vs $opp.');
    }

    final saved = persist ? await MatchStore.load(me) : null;
    if (saved != null && saved.matchId == matchId && saved.accountId == me) {
      _applyLocal(saved);
    }

    final play = await refresh();
    if (play.state != 'Created' && !rosterReady) {
      log =
          'Rejoined, but this device has no sealed army for the match. '
          'Fights need the original salts.';
    } else if (!accepted) {
      log = 'Rejoined as creator. Share ${formatJoinKey(joinKey ?? '')}.';
    } else if (rosterReady) {
      log = 'Rejoined match. Army restored.';
    } else {
      log = 'Rejoined match. Arrange your army.';
    }
    await _persistLocal();
    progress = null;
  }

  /// Writes current match binding (+ army when sealed) for reconnect.
  Future<void> _persistLocal() async {
    final id = matchId;
    if (id == null || !persist) return;
    await MatchStore.save(
      MatchLocalState(
        matchId: id,
        joinKey: joinKey ?? '',
        accountId: me,
        sideA: sideA,
        rosterReady: rosterReady,
        ranks: rosterReady ? ranks : const [],
        squares: rosterReady ? squares : const [],
        salts: rosterReady ? salts : const [],
      ),
    );
  }

  /// Restores ranks / salts from a prior [MatchLocalState].
  ///
  /// Does **not** restore [sideA] — that always comes from `get_match`.
  void _applyLocal(MatchLocalState saved) {
    if (saved.joinKey.isNotEmpty) joinKey = saved.joinKey;
    if (!saved.rosterReady) return;
    if (saved.ranks.length != 21 ||
        saved.squares.length != 21 ||
        saved.salts.length != 21) {
      return;
    }
    ranks = List<Rank>.from(saved.ranks);
    squares = List<(int, int)>.from(saved.squares);
    salts = List<Uint8List>.from(saved.salts);
    rosterReady = true;
    setup.clear();
    for (var i = 0; i < 21; i++) {
      final (file, boardRank) = squares[i];
      setup[MatchGame.sq(file, boardRank)] = ranks[i];
    }
  }

  /// Commits the arranged 21-piece army as 32-byte hashes on home squares.
  Future<void> commitArmy() async {
    if (setup.length != 21) {
      throw StateError('Place all 21 pieces first.');
    }
    progress = 'Committing army to NEAR…';
    final placed = setup.entries.toList();
    final nextRanks = [for (final entry in placed) entry.value];
    final nextSquares = [
      for (final entry in placed)
        (MatchGame.fileOf(entry.key), MatchGame.rankOf(entry.key)),
    ];
    final nextSalts = List.generate(21, (_) {
      final r = Random.secure();
      return Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256)));
    });
    final placements = <List<dynamic>>[];
    for (var i = 0; i < 21; i++) {
      final (file, boardRank) = nextSquares[i];
      placements.add([
        file,
        boardRank,
        pieceCommitment(nextRanks[i], nextSalts[i]),
      ]);
    }
    await near.call('commit_setup', {
      'match_id': matchId,
      'placements': placements,
    });
    ranks = nextRanks;
    squares = nextSquares;
    salts = nextSalts;
    rosterReady = true;
    log = 'Army committed.';
    await _persistLocal();
    progress = null;
  }

  /// Fills the default layout and commits it (scripts and old callers).
  Future<void> commitDefault() async {
    setupAutoFill();
    await commitArmy();
  }

  /// Locks this army if needed, then `confirm_roster` once both are locked.
  ///
  /// With the opponent still arranging, returns quietly: the match driver
  /// starts the match as soon as a sync shows both armies on chain. Pass
  /// [silent] from the driver so the overlay text does not flash.
  ///
  /// Both phones racing to start is normal, so a "wrong state" panic here
  /// means the other one won and is not an error.
  Future<void> confirmRoster({bool silent = false}) async {
    if (!rosterReady) {
      await commitArmy();
    }
    var snap = await refresh();
    if (snap.state != 'Created') {
      _applyFirstPlayerLog(snap);
      return;
    }
    if (!snap.bothSetups) {
      log = 'Army locked. Waiting for opponent…';
      _changed();
      return;
    }
    if (!silent) progress = 'Starting match…';
    try {
      await near.call('confirm_roster', {'match_id': matchId});
    } catch (e) {
      final msg = e.toString();
      if (_setupsIncomplete(msg)) {
        log = 'Army locked. Waiting for opponent…';
        return;
      }
      if (!_wrongState(msg)) rethrow;
    } finally {
      if (!silent) progress = null;
    }
    snap = await refresh();
    _applyFirstPlayerLog(snap);
  }

  void _applyFirstPlayerLog(PlaySnap play) {
    if (play.toMove.isNotEmpty && play.nonceA == 0 && play.nonceB == 0) {
      first = play.toMove;
    }
    if (first != null) {
      _applyFirstPlayerLogFromFirst();
      if (play.state != 'Created' && play.toMove.isNotEmpty) {
        log = first == sideLabel
            ? 'Roster confirmed — you move first (light).'
            : 'Roster confirmed — opponent moves first (you are dark).';
      }
    } else if (play.state != 'Created') {
      log = 'Roster confirmed.';
    }
  }

  /// Contract [MatchError::SetupsIncomplete] display / panic text.
  static bool _setupsIncomplete(String msg) =>
      msg.contains('both setups are required') ||
      msg.contains('SetupsIncomplete');

  /// Contract [MatchError::WrongState] display / panic text.
  static bool _wrongState(String msg) =>
      msg.contains('illegal source state') || msg.contains('WrongState');

  /// Reads one `get_sync` row and, unless it is stale, makes it [play].
  ///
  /// One view, one block: turn, clocks, seats and board are replaced
  /// together. A row from a block older than the one already applied (a
  /// slower node answered) is dropped, so the screen never steps backwards.
  /// Returns the row now in force.
  Future<PlaySnap> refresh() async {
    final id = matchId;
    if (id == null) throw StateError('No match to sync.');
    final raw = await near.view('get_sync', {'match_id': id});
    final at = monoNs();
    final prev = play;
    if (raw is! List || raw.length < 4) {
      // A node that has not caught up to the match yet is just a stale
      // reply once we have seen the match ourselves.
      if (prev != null) {
        staleDropped++;
        return prev;
      }
      throw StateError('Match $id not found on chain.');
    }
    final next = PlaySnap.fromSync(raw);
    if (prev != null &&
        next.height < prev.height &&
        prev.height - next.height < _staleHeightWindow) {
      staleDropped++;
      return prev;
    }
    _applySync(next, raw, at);
    if (next.state == 'Ended' && outcomeKind == null) {
      await _loadOutcome();
      await _loadSettlement();
      result ??= _outcomeBanner();
      log = result!;
      _changed();
    }
    return next;
  }

  /// Installs [next] as the row in force. [at] is when it arrived.
  void _applySync(PlaySnap next, List<dynamic> raw, int at) {
    final offset = next.chainNowNs - at;
    final known = _chainOffsetNs;
    if (known == null || offset > known) _chainOffsetNs = offset;

    final seats = raw[2] as List<dynamic>;
    final creator = seats[0] as String;
    final opp = seats[1] as String;
    // The seat always comes from the chain, never from local storage.
    if (me == creator) {
      sideA = true;
    } else if (me == opp) {
      sideA = false;
    } else if (opp != openOpponentAccount) {
      throw StateError('Signed in as $me, but this match is $creator vs $opp.');
    }
    final nowAccepted = seats[2] as bool;
    if (!accepted && nowAccepted && sideA && !rosterReady) {
      log = 'Opponent joined. Arrange your army.';
    }
    accepted = nowAccepted;
    final f = seats[3] as String;
    if (f == 'A' || f == 'B') {
      final wasNull = first == null;
      first = f;
      if (wasNull && accepted && !rosterReady) _applyFirstPlayerLogFromFirst();
    }

    occupancy = [for (final cell in raw[3] as List<dynamic>) cell as int];
    syncGraveyard();

    final prev = play;
    play = next;
    if (prev != null) _measureStreamDelay(prev, next, at);

    // Legacy matches without `first`: while no move has been played, the
    // side to move is the first player.
    if (first == null &&
        next.toMove.isNotEmpty &&
        next.nonceA == 0 &&
        next.nonceB == 0 &&
        next.live) {
      first = next.toMove;
    }

    // My thinking time runs from when this phone first shows the turn.
    if (next.ticking &&
        next.toMove == sideLabel &&
        _turnSeenKey != next.turnStartedAtNs) {
      _turnSeenKey = next.turnStartedAtNs;
      _turnSeenMonoNs = at;
      _announceTurnSeen(next);
    }

    // A new turn for them: forget the last seen/tap notes.
    if (prev == null ||
        prev.toMove != next.toMove ||
        prev.turnStartedAtNs != next.turnStartedAtNs) {
      if (next.toMove != sideLabel) {
        _theirSeen = null;
      }
    }

    final p = pending;
    if (p != null && next.nonceOf(sideLabel) > p.nonce) pending = null;
    _changed();
  }

  /// Learns how late the opponent's moves reach this phone.
  ///
  /// Their clock stops when they tap, but this phone hears of it later:
  /// through the mailbox note if it arrives, else once the move is in a
  /// block and a sync has fetched it. Drawn live, their clock would overrun
  /// by that lag on every move and then jump back. So it is drawn
  /// [_streamDelayNs] behind instead, like a broadcast delay: it starts a
  /// moment late and stops on the right number.
  void _measureStreamDelay(PlaySnap prev, PlaySnap next, int at) {
    final them = sideA ? 'B' : 'A';
    if (!prev.ticking || prev.toMove != them) return;
    if (next.nonceOf(them) != prev.nonceOf(them) + 1) return;
    // Already measured when the note for this move came in.
    if (_theirTap?.nonce == prev.nonceOf(them)) return;
    _noteStreamLag(prev, prev.bankNs(them) - next.bankNs(them), at);
  }

  /// Records one lag sample: their turn of [snap] was watched until [at]
  /// and [charged] of it turned out to be thinking.
  void _noteStreamLag(PlaySnap snap, int charged, int at) {
    final offset = _chainOffsetNs;
    if (offset == null) return;
    final watched = at + offset - snap.turnStartedAtNs;
    final lag = watched - charged;
    if (charged < 0 || lag < 0 || lag > 3 * lagCapNs) return;
    _streamLags.add(lag);
    if (_streamLags.length > 6) _streamLags.removeAt(0);
    // Upper quartile: one slow move does not stretch the delay, but the
    // delay sits a little high so the clock lands forward, not backward.
    final sorted = [..._streamLags]..sort();
    final pick = sorted[min(sorted.length - 1, (sorted.length * 3) ~/ 4)];
    _streamDelayNs = pick.clamp(_streamDelayMinNs, _streamDelayMaxNs);
  }

  static String _tapNoteKey(String side, int nonce) => 'tap-$side-$nonce';

  static String _seenNoteKey(String side, int turnStartedAtNs) =>
      'seen-$side-$turnStartedAtNs';

  static String _arriveNoteKey(String slot) => 'arrive-$slot';

  /// Tells the opponent's phone this side has tapped. Best effort.
  void _announceTap(PendingMove p) {
    if (!tapNotes) return;
    unawaited(
      mailbox
          .put('$matchId', _tapNoteKey(sideLabel, p.nonce), '${p.faceNs}')
          .catchError((Object _) {}),
    );
  }

  /// Tells the opponent this phone can act on the current turn. Best effort.
  void _announceTurnSeen(PlaySnap snap) {
    unawaited(
      mailbox
          .put('$matchId', _seenNoteKey(sideLabel, snap.turnStartedAtNs), '1')
          .catchError((Object _) {}),
    );
  }

  /// Asks the mailbox whether the opponent has tapped or can act. Display only.
  ///
  /// Cheap and safe to call often, from outside the driver's lock: it reads
  /// at most two blobs and can only change how the opponent's clock is drawn.
  Future<void> pollOpponentTap() async {
    final before = play;
    final them = sideA ? 'B' : 'A';
    if (before == null || !before.ticking || before.toMove != them) return;
    await _pollTurnSeen(before, them);
    if (!tapNotes) return;
    final nonce = before.nonceOf(them);
    if (_theirTap?.nonce == nonce) return;
    final blob = await mailbox.get('$matchId', _tapNoteKey(them, nonce));
    final at = monoNs();
    final face = blob == null ? null : int.tryParse(blob);
    if (face == null) return;
    // The world may have moved on while the mailbox answered.
    final snap = play;
    if (snap == null ||
        !snap.ticking ||
        snap.toMove != them ||
        snap.nonceOf(them) != nonce ||
        _theirTap?.nonce == nonce) {
      return;
    }
    final bank = snap.bankNs(them);
    if (face < 0 || face > bank) return;
    _noteStreamLag(snap, bank - face, at);
    _theirTap = (nonce: nonce, faceNs: face, atMonoNs: at);
    tapNotesUsed++;
    _changed();
  }

  Future<void> _pollTurnSeen(PlaySnap before, String them) async {
    if (_theirSeen?.turnStartedAtNs == before.turnStartedAtNs) return;
    // A tap already means they could act.
    if (_theirTap != null && _theirTap!.nonce == before.nonceOf(them)) {
      _theirSeen = (
        turnStartedAtNs: before.turnStartedAtNs,
        atMonoNs: monoNs(),
      );
      return;
    }
    final blob = await mailbox.get(
      '$matchId',
      _seenNoteKey(them, before.turnStartedAtNs),
    );
    if (blob == null) return;
    final snap = play;
    if (snap == null ||
        !snap.ticking ||
        snap.toMove != them ||
        snap.turnStartedAtNs != before.turnStartedAtNs ||
        _theirSeen?.turnStartedAtNs == before.turnStartedAtNs) {
      return;
    }
    _theirSeen = (turnStartedAtNs: before.turnStartedAtNs, atMonoNs: monoNs());
    turnSeenNotesUsed++;
    _changed();
  }

  /// True once this phone knows the opponent can act on [snap]'s turn.
  bool _opponentCanAct(PlaySnap snap, String them) {
    if (_theirSeen?.turnStartedAtNs == snap.turnStartedAtNs) return true;
    final tap = _theirTap;
    if (tap != null && tap.nonce == snap.nonceOf(them)) return true;
    // Move already left their phone: stop holding.
    return false;
  }

  /// The opponent's clock face from a fresh tap note for this turn, if any.
  int? _theirHeldFaceNs(PlaySnap snap, String them) {
    final note = _theirTap;
    if (note == null || note.nonce != snap.nonceOf(them)) return null;
    if (monoNs() - note.atMonoNs > _tapNoteTtlNs) return null;
    return note.faceNs;
  }

  /// Best estimate of chain time now (ns), or null before the first sync.
  ///
  /// Never ahead of the chain, and never moves backwards.
  int? get chainNowNs {
    final offset = _chainOffsetNs;
    return offset == null ? null : monoNs() + offset;
  }

  /// Chain time elapsed in the current turn of [snap].
  int _chainElapsedNs(PlaySnap snap) {
    if (snap.turnStartedAtNs == 0) return 0;
    final now = chainNowNs ?? snap.chainNowNs;
    return max(0, now - snap.turnStartedAtNs);
  }

  /// What this side will be charged if it moves now.
  ///
  /// Time the turn has been on this screen, but never less than the chain
  /// will charge anyway once the network credit is used up.
  int _myElapsedNs(PlaySnap snap) {
    final seen = _turnSeenMonoNs;
    final shown = seen == null ? 0 : monoNs() - seen;
    return max(0, max(shown, _chainElapsedNs(snap) - lagCapNs));
  }

  /// Time left for `"A"` or `"B"` as drawn on this phone (ns), never negative.
  ///
  /// A clock that is not running shows the chain's bank, so both phones
  /// agree at rest. My running clock is timed locally from when the turn
  /// appeared and holds from the tap. The opponent's running clock stays at
  /// the bank until their phone can act, then is drawn [_streamDelayNs]
  /// behind chain time, and holds again when they tap.
  int remainingNs(String side) {
    final snap = play;
    if (snap == null) return 0;
    final bank = snap.bankNs(side);
    final mine = side == sideLabel;
    if (mine && pending != null) return pending!.faceNs;
    if (!snap.ticking || snap.toMove != side) return bank;
    if (mine) return max(0, bank - _myElapsedNs(snap));
    final held = _theirHeldFaceNs(snap, side);
    if (held != null) return held;
    if (!_opponentCanAct(snap, side)) return bank;
    return max(0, bank - max(0, _chainElapsedNs(snap) - _streamDelayNs));
  }

  /// True while [side]'s clock is being counted down on this screen.
  bool clockRunning(String side) {
    final snap = play;
    if (snap == null || !snap.ticking || snap.toMove != side) return false;
    if (side == sideLabel) return pending == null;
    if (_theirHeldFaceNs(snap, side) != null) return false;
    return _opponentCanAct(snap, side);
  }

  /// [remainingNs] as a [Duration].
  Duration remainingFor(String side) =>
      Duration(microseconds: remainingNs(side) ~/ 1000);

  /// `m:ss` or `h:mm:ss` for [side].
  String formatFor(String side) => formatClock(remainingFor(side));

  /// Current broadcast delay on the opponent's clock (ns). For diagnostics.
  int get streamDelayNs => _streamDelayNs;

  /// Pulls `get_outcome` when the contract has it.
  Future<void> _loadOutcome() async {
    try {
      final raw = await near.view('get_outcome', {'match_id': matchId});
      if (raw is! List || raw.length < 3) return;
      outcomeKind = raw[0] as String;
      outcomeWinner = raw[1] as String;
      outcomeReason = raw[2] as String;
      if (outcomeReason == 'FlagBreakthrough') _revealBreakthroughFlag();
      result = _outcomeBanner();
    } catch (_) {}
  }

  /// Shows the Flag that won by sitting on the far rank.
  void _revealBreakthroughFlag() {
    final at = _flagAt;
    final occ = _flagOcc ?? (at == null ? 0 : occupancy[at]);
    if (occ == 0) return;
    if (occ < opened.length) opened[occ] = Rank.flag.index;
    // Winner already knows; loser learns the square from occupancy on
    // the far rank belonging to the winner.
    if (_flagAt == null && outcomeWinner != null) {
      final home = outcomeWinner == 'A' ? 7 : 0;
      for (var sq = home * 9; sq < home * 9 + 9; sq++) {
        final o = occupancy[sq];
        if (o == 0) continue;
        final theirs = outcomeWinner == 'A' ? o <= 21 : o >= 22;
        if (theirs) {
          _flagAt = sq;
          _flagOcc = o;
          if (o < opened.length) opened[o] = Rank.flag.index;
          break;
        }
      }
    }
    _changed();
  }

  /// Top line for an ended match (`You win!` / `You lost!` / …).
  String get endHeadline {
    if (outcomeKind == 'Win' &&
        outcomeWinner != null &&
        outcomeWinner!.isNotEmpty) {
      return outcomeWinner == sideLabel ? 'You win!' : 'You lost!';
    }
    if (outcomeKind == 'Draw') return 'Draw';
    if (outcomeKind == 'Void') return 'Match voided';
    if (result != null && result!.isNotEmpty) {
      // Local-only paths (e.g. resign before outcome loads).
      if (result!.startsWith('You resigned')) return 'You lost!';
      return result!;
    }
    return 'Match over';
  }

  /// Second line: why the match ended, from this phone's point of view.
  String? get endCause {
    if (outcomeReason == 'Timeout' &&
        outcomeWinner != null &&
        outcomeWinner!.isNotEmpty) {
      return outcomeWinner == sideLabel
          ? "Opponent's time expired"
          : 'Your time expired';
    }
    if (outcomeReason == 'Resignation' &&
        outcomeWinner != null &&
        outcomeWinner!.isNotEmpty) {
      return outcomeWinner == sideLabel ? 'Opponent resigned' : 'You resigned';
    }
    return _reasonPhrase(outcomeReason);
  }

  /// Single-line banner for logs / overlays (headline + cause).
  String _outcomeBanner() {
    final cause = endCause;
    if (cause == null || cause.isEmpty) return endHeadline;
    return '$endHeadline $cause';
  }

  /// Short English phrase for a wire win/draw reason, or null.
  static String? _reasonPhrase(String? wire) {
    switch (wire) {
      case 'FlagCaptured':
        return 'Flag captured';
      case 'FlagBreakthrough':
        return 'Flag reached the far rank';
      case 'Resignation':
        return 'Resignation';
      case 'Immobilised':
        return 'Opponent immobilised';
      case 'Timeout':
        return 'Time expired';
      case 'Agreement':
        return 'Agreement';
      case 'Repetition':
        return 'Threefold repetition';
      case 'OpponentForfeited(InvalidSetup)':
        return 'Opponent forfeited (invalid setup)';
      case 'OpponentForfeited(SettlementTimeout)':
        return 'Opponent forfeited (settlement timeout)';
      default:
        return null;
    }
  }

  /// Opens this side's salts, then tries `settle`. Idempotent.
  Future<void> flipIfEnded() async {
    if (play?.state != 'Ended') return;
    if (!_submittedSetup) {
      if (!rosterReady) {
        log = 'Match ended. No local salts to reveal.';
        return;
      }
      progress = 'Revealing your army…';
      await _submitSetup();
      _submittedSetup = true;
    }
    await _loadOpened();
    await _loadSettlement();
    if (settlement == 'Settled' ||
        settlement == 'Forfeited' ||
        settlement == 'Voided') {
      await _loadOutcome();
      result = _outcomeBanner();
      if (settlement == 'Settled') {
        result = '${result!} Board is public.';
      }
      log = result!;
      progress = null;
      await claimPayoutIfNeeded();
      return;
    }
    if (_settleTried && settlement == 'AwaitingFlip') {
      log = '${_outcomeBanner()} Waiting for the other army to reveal…';
      progress = null;
      return;
    }
    _settleTried = true;
    try {
      progress = 'Settling match on NEAR…';
      await near.call('settle', {'match_id': matchId});
      settlement = 'Settled';
      await _loadOpened();
      await _loadOutcome();
      result = '${_outcomeBanner()} Board is public.';
      log = result!;
      progress = null;
      await claimPayoutIfNeeded();
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('FlipIncomplete') ||
          msg.contains('both sides have not')) {
        await _loadOutcome();
        log = '${_outcomeBanner()} Waiting for the other army to reveal…';
        progress = null;
        _settleTried = false;
      } else if (_wrongState(msg) || msg.contains('illegal source')) {
        await _loadSettlement();
        await _loadOutcome();
        result = _outcomeBanner();
        log = result!;
        progress = null;
        await claimPayoutIfNeeded();
      } else {
        progress = null;
        rethrow;
      }
    }
  }

  /// True when this match escrows NEAR.
  bool get hasStake {
    final v = BigInt.tryParse(stakeYocto) ?? BigInt.zero;
    return v > BigInt.zero;
  }

  /// Permissionless `claim_payout` after a terminal settlement with a pot.
  Future<void> claimPayoutIfNeeded() async {
    if (payoutClaimed || !hasStake) return;
    if (settlement != 'Settled' &&
        settlement != 'Forfeited' &&
        settlement != 'Voided') {
      return;
    }
    progress = 'Claiming pot…';
    try {
      await near.call('claim_payout', {'match_id': matchId});
      payoutClaimed = true;
      log = '${result ?? _outcomeBanner()} Pot claimed.';
      _changed();
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('AlreadyPaid') || msg.contains('already paid')) {
        payoutClaimed = true;
      } else if (!_wrongState(msg)) {
        progress = null;
        rethrow;
      }
    } finally {
      progress = null;
    }
  }

  /// `submit_setup` with this phone's 21 openings.
  Future<void> _submitSetup() async {
    await near.call('submit_setup', {
      'match_id': matchId,
      'pieces': [
        for (var i = 0; i < 21; i++)
          [rankWire[ranks[i].index], squares[i].$1, squares[i].$2, salts[i]],
      ],
    });
    log = 'Army revealed.';
  }

  /// Pulls `get_opened` if the contract has it.
  Future<void> _loadOpened() async {
    try {
      final raw = await near.view('get_opened', {'match_id': matchId});
      if (raw is List) {
        opened = raw.map((e) => e as int).toList();
      }
    } catch (_) {}
  }

  /// Status copy once [first] is known (accept), before roster confirm.
  void _applyFirstPlayerLogFromFirst() {
    if (first == sideLabel) {
      log = 'You are light — you will move first.';
    } else if (first != null) {
      log = 'You are dark — opponent moves first.';
    }
  }

  /// Pulls `get_settlement`.
  Future<void> _loadSettlement() async {
    try {
      final raw = await near.view('get_settlement', {'match_id': matchId});
      if (raw is String) settlement = raw;
    } catch (_) {}
  }

  /// Whether occupancy [occ] is this phone's piece (1–21 or 22–42).
  bool mine(int occ) => sideA ? occ >= 1 && occ <= 21 : occ >= 22 && occ <= 42;

  /// Rank of [occ] if opened on chain, or mine and [commitArmy] has run.
  Rank? rankOfOcc(int occ) {
    if (occ > 0 && occ < opened.length && opened[occ] <= 14) {
      return Rank.values[opened[occ]];
    }
    if (!rosterReady || !mine(occ)) return null;
    return ranks[sideA ? occ - 1 : occ - 22];
  }

  /// Own defeated ranks for the graveyard strip. Never includes the opponent.
  List<Rank> get myGraveyard {
    if (!rosterReady) return const [];
    return [
      for (final occ in graveyardOcc)
        if (rankOfOcc(occ) != null) rankOfOcc(occ)!,
    ];
  }

  /// Appends missing own pieces once the board is live (not empty setup).
  void syncGraveyard() {
    if (!rosterReady) return;
    if (occupancy.every((occ) => occ == 0)) return;
    final alive = occupancy.where(mine).toSet();
    final lo = sideA ? 1 : 22;
    final hi = sideA ? 21 : 42;
    for (var occ = lo; occ <= hi; occ++) {
      if (alive.contains(occ)) continue;
      if (graveyardOcc.contains(occ)) continue;
      graveyardOcc.add(occ);
    }
  }

  /// True when the match is over and nothing is left to report.
  bool get finished =>
      settlement == 'Settled' ||
      settlement == 'Forfeited' ||
      settlement == 'Voided';

  /// Whether this phone may move: its turn on chain and no move in flight.
  ///
  /// False from the instant of a tap, long before the chain hears of it.
  bool get myTurn {
    final snap = play;
    return snap != null &&
        pending == null &&
        result == null &&
        snap.ticking &&
        snap.toMove == sideLabel;
  }

  /// [myTurn] with time still on the clock.
  bool get canAct => myTurn && remainingNs(sideLabel) > 0;

  /// The one-line state shown above the board.
  String get statusLine {
    if (!accepted) return 'Waiting for opponent';
    if (settingUp) return 'Set your pieces - $setupRemaining left';
    final snap = play;
    if (snap == null) return 'Match';
    if (snap.state == 'Created') {
      return snap.bothSetups
          ? 'Starting match…'
          : 'Army locked · waiting for opponent';
    }
    if (snap.state == 'Ended') return 'Match over';
    final p = pending;
    if (p != null) return p.attack ? 'Battle!' : 'Moving…';
    // Home-row confirms stay as "Moving…": naming them would announce the
    // far-rank step. Fights still say Battle!.
    if (snap.waiting) return waitingIsFight() ? 'Battle!' : 'Moving…';
    if (snap.toMove.isEmpty) return 'Match';
    final mine = snap.toMove == sideLabel;
    // Breakthrough is silent: same chrome as a normal turn. The board
    // already shows a piece on the far rank; the chain decides the rest.
    if (!mine) return "Opponent's turn";
    return remainingNs(sideLabel) > 0 ? 'Your turn' : 'Out of time';
  }

  /// Local geometry + occupancy check before spending a tx.
  ///
  /// One orthogonal step onto empty or an enemy piece. Own pieces are illegal
  /// destinations (tap them to re-select instead).
  bool canMove(int from, int to) {
    if (!mine(occupancy[from])) return false;
    if (!MatchGame.isOrthogonalStep(from, to)) return false;
    final dest = occupancy[to];
    return dest == 0 || !mine(dest);
  }

  /// Commits to a move at the instant of the tap. Synchronous on purpose.
  ///
  /// From here the turn is no longer this phone's: [myTurn] is false, the
  /// overlay is up and the clock holds at what it showed. Nothing is sent
  /// yet; [submitMove] does that. Returns false if the move cannot be made.
  bool beginMove(int from, int to) {
    final snap = play;
    if (snap == null || !myTurn) return false;
    if (!canMove(from, to)) {
      log = 'Illegal move — only an adjacent empty or enemy square.';
      return false;
    }
    final think = _myElapsedNs(snap);
    final face = snap.bankNs(sideLabel) - think;
    if (face <= 0) return false;
    pending = PendingMove(
      from: from,
      to: to,
      nonce: snap.nonceOf(sideLabel),
      attack: occupancy[to] != 0,
      thinkNs: think,
      faceNs: face,
      tappedMonoNs: monoNs(),
    );
    selected = null;
    _announceTap(pending!);
    _changed();
    return true;
  }

  /// Sends the move from [beginMove] and waits until the chain shows it.
  ///
  /// Signature fields are empty: the predecessor is us. Returns once a
  /// sync shows this side's nonce advanced, which also clears [pending], so
  /// the overlay never drops before the board and turn have changed.
  ///
  /// The chain has the last word on every outcome. After any error the
  /// match is re-read first: if the move is there, it succeeded. A refused
  /// move clears [pending] and rethrows. An unclear send (timeout, lost
  /// connection) is sent once more, which is safe because the match nonce
  /// lets only one copy through, and then watched for before giving up.
  Future<void> submitMove() async {
    final p = pending;
    if (p == null) return;
    var unsure = false;
    for (var attempt = 0; attempt < 2 && identical(pending, p); attempt++) {
      try {
        await near.call('apply_moves', {
          'match_id': matchId,
          'moves': [
            {
              'match_id': matchId,
              'from': p.from,
              'to': p.to,
              'nonce': p.nonce,
              'public_key': <int>[],
              'signature': <int>[],
            },
          ],
          'think_ns': '${p.thinkNs}',
        });
        p.sent = true;
        unsure = false;
        log = 'Move sent.';
        _changed();
        break;
      } catch (e) {
        try {
          await refresh();
        } catch (_) {
          // A failed read says nothing about the move.
        }
        if (!identical(pending, p)) return;
        if (!_outcomeUnknown(e)) {
          pending = null;
          _changed();
          rethrow;
        }
        unsure = true;
      }
    }
    final unsureSince = unsure ? monoNs() : null;
    while (identical(pending, p)) {
      try {
        await refresh();
      } catch (_) {
        // A failed read says nothing about the move. Keep watching.
      }
      if (!identical(pending, p)) break;
      if (unsureSince != null && monoNs() - unsureSince > _confirmDeadlineNs) {
        pending = null;
        _changed();
        throw StateError('Your move did not reach NEAR. Try again.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// [beginMove] then [submitMove], for scripts.
  Future<void> move(int from, int to) async {
    if (beginMove(from, to)) await submitMove();
  }

  /// True when [e] leaves it open whether the transaction was included.
  static bool _outcomeUnknown(Object e) {
    if (e is TimeoutException) return true;
    final msg = e.toString();
    return msg.contains('network error') || msg.contains('timed out');
  }

  /// `"A"` or `"B"` for a non-empty occupancy value.
  static String _sideOfOcc(int occ) => occ <= 21 ? 'A' : 'B';

  /// Mailbox / bookkeeping key for the wait in [snap].
  ///
  /// Includes both nonces: the same two squares can be fought over again
  /// later in a match, and that must be a new exchange with new keys.
  static String _slotOf(PlaySnap snap) =>
      '${snap.waitFrom}-${snap.waitTo}-${snap.nonceA}-${snap.nonceB}';

  /// True when [snap] (default: [play]) waits on a piece-vs-piece fight.
  ///
  /// Mirrors the contract: the destination holds a piece that is not the
  /// mover's. After a quiet step onto the far rank the mover's own piece is
  /// already there, which is an arrival, not a fight.
  bool waitingIsFight([PlaySnap? snap]) {
    final s = snap ?? play;
    if (s == null || !s.waiting) return false;
    final toOcc = occupancy[s.waitTo];
    return toOcc != 0 && _sideOfOcc(toOcc) != s.toMove;
  }

  /// Runs OT + `resolve_challenge`, or `confirm_arrival`, if [play] waits.
  Future<void> resolveIfWaiting() async {
    final snap = play;
    if (snap == null || !snap.waiting) return;
    final slot = _slotOf(snap);
    if (_reported.contains(slot)) return;
    if (waitingIsFight(snap)) {
      await _fight(snap, slot);
    } else {
      await _arrival(slot);
    }
  }

  /// One offer / seal / report per [slot]. Regenerating keys breaks MAC.
  Future<void> _fight(PlaySnap snap, String slot) async {
    final fromOcc = occupancy[snap.waitFrom];
    final toOcc = occupancy[snap.waitTo];
    final iAmAttacker = snap.toMove == sideLabel;
    if (iAmAttacker) {
      progress = 'Waiting for defender…';
      if (!_sealed.contains(slot)) {
        final offer = await mailbox.get('$matchId', 'recv-$slot');
        if (offer == null || offer.isEmpty) {
          log = 'Waiting for defender keys…';
          return;
        }
        progress = 'Sealing attack…';
        await mailbox.put(
          '$matchId',
          'send-$slot',
          await otSealRow(rankOfOcc(fromOcc)!, decodeOffer(offer)),
        );
        _sealed.add(slot);
      }
      progress = 'Waiting for open…';
      final opened = await mailbox.get('$matchId', 'open-$slot');
      if (opened == null || opened.isEmpty) {
        log = 'Waiting for defender to open…';
        return;
      }
      final parts = opened.split('|');
      progress = 'Reporting to NEAR…';
      await _report(
        slot,
        () => _reportFight(
          exchangeFromWire(parts[0]),
          parts.length > 1 && parts[1] == '1',
        ),
      );
      return;
    }
    final def = rankOfOcc(toOcc)!;
    // One set of keys per fight: the attacker may already have sealed to
    // them. Publishing is a separate step so a failed upload is retried
    // with the same keys instead of leaving the attacker waiting for ever.
    var offer = _offers[slot];
    if (offer == null) {
      progress = 'Publishing keys…';
      offer = await otOffer(def);
      _offers[slot] = offer;
    }
    if (!_published.contains(slot)) {
      progress = 'Publishing keys…';
      await mailbox.put(
        '$matchId',
        'recv-$slot',
        encodeOffer(offer.publicKeys),
      );
      _published.add(slot);
    }
    progress = 'Waiting for attack…';
    final sealed = await mailbox.get('$matchId', 'send-$slot');
    if (sealed == null || sealed.isEmpty) {
      log = 'Waiting for attacker row…';
      return;
    }
    progress = 'Opening sealed row…';
    final ex = await otOpenCell(sealed, def, offer.secret!);
    final flag = def == Rank.flag;
    await mailbox.put(
      '$matchId',
      'open-$slot',
      '${exchangeWire(ex)}|${flag ? 1 : 0}',
    );
    progress = 'Reporting to NEAR…';
    await _report(slot, () => _reportFight(ex, flag));
  }

  /// Dual-report empty-square home-row step. Silent in the UI.
  ///
  /// The mover knows whether the piece is their Flag and posts that bit
  /// in the mailbox; the opponent echoes it. Both reports must match or
  /// the match voids. Nothing on screen says "arrival" or "breakthrough":
  /// if it was the Flag, the chain opens a one-turn window and ends the
  /// match when that turn does not challenge the square.
  Future<void> _arrival(String slot) async {
    final snap = play;
    if (snap == null || !snap.waiting) return;
    final iAmMover = snap.toMove == sideLabel;
    late final bool isFlag;
    if (iAmMover) {
      isFlag = rankOfOcc(occupancy[snap.waitTo]) == Rank.flag;
      await mailbox.put('$matchId', _arriveNoteKey(slot), isFlag ? '1' : '0');
      if (isFlag) {
        _flagAt = snap.waitTo;
        _flagOcc = occupancy[snap.waitTo];
      }
    } else {
      final blob = await mailbox.get('$matchId', _arriveNoteKey(slot));
      if (blob == null || blob.isEmpty) {
        log = 'Confirming…';
        return;
      }
      isFlag = blob == '1';
      if (isFlag) {
        _flagAt = snap.waitTo;
        _flagOcc = occupancy[snap.waitTo];
      }
    }
    progress = 'Confirming…';
    await _report(slot, () async {
      await near.call('confirm_arrival', {
        'match_id': matchId,
        'is_flag': isFlag,
      });
      log = 'Move confirmed.';
    });
  }

  /// Sends this side's report for [slot] once.
  ///
  /// The contract takes one report per side per wait. "Wrong state" means
  /// ours is already in (an earlier send landed after all) or the wait is
  /// already resolved; both are done, not errors.
  Future<void> _report(String slot, Future<void> Function() send) async {
    try {
      await send();
    } catch (e) {
      if (!_wrongState(e.toString())) rethrow;
    } finally {
      progress = null;
    }
    _reported.add(slot);
    _changed();
  }

  /// `resolve_challenge` with the opened [Exchange] and Flag bit.
  Future<void> _reportFight(Exchange ex, bool flag) async {
    await near.call('resolve_challenge', {
      'match_id': matchId,
      'exchange': exchangeWire(ex),
      'flag_captured': flag,
    });
    log = 'Fight reported: ${exchangeWire(ex)}.';
  }

  /// `resign`. Sets [result].
  Future<void> resign() async {
    progress = 'Resigning…';
    try {
      await near.call('resign', {'match_id': matchId});
      result = 'You resigned.';
      log = result!;
    } finally {
      progress = null;
    }
  }

  /// True when the chain would accept `claim_timeout` for the side to move.
  ///
  /// The contract waits [lagCapNs] past zero, so a move tapped in time and
  /// still in flight is never beaten by a claim. The estimate of chain time
  /// is never ahead, so this is never true too early.
  bool sideToMoveTimedOut() {
    final snap = play;
    if (snap == null || !snap.ticking || pending != null) return false;
    if (monoNs() < _claimNotBeforeMonoNs) return false;
    return _chainElapsedNs(snap) >= snap.bankNs(snap.toMove) + lagCapNs;
  }

  /// Permissionless `claim_timeout` — opponent of the flagged side wins.
  Future<void> claimTimeout() async {
    progress = 'Clock expired — ending match…';
    try {
      await near.call('claim_timeout', {'match_id': matchId});
    } catch (e) {
      // A move landed first, or the other phone already claimed.
      if (!_wrongState(e.toString())) rethrow;
      _claimNotBeforeMonoNs = monoNs() + 2 * 1000 * 1000 * 1000;
    } finally {
      progress = null;
    }
    await refresh();
  }

  /// Overlay copy: big title + optional quiet sublabel, or null for none.
  ///
  /// Up from the tap until the chain shows the move, and for a battle all
  /// the way until the fight is resolved, so no half-updated state is ever
  /// on show. A quiet opponent turn uses the status line instead.
  ({String title, String? subtitle})? activity() {
    final busyLine = (progress != null && progress!.isNotEmpty)
        ? progress
        : null;
    final p = pending;
    if (p != null) {
      if (p.attack) {
        return (
          title: 'Battle!',
          subtitle: p.sent ? 'Confirming…' : 'Sending attack…',
        );
      }
      return (
        title: 'Moving…',
        subtitle: p.sent ? 'Confirming…' : 'Sending to NEAR…',
      );
    }
    final snap = play;
    if (snap != null && snap.waiting) {
      final reported = _reported.contains(_slotOf(snap));
      if (waitingIsFight(snap)) {
        return (
          title: 'Battle!',
          subtitle:
              busyLine ?? (reported ? 'Waiting for opponent…' : 'Resolving…'),
        );
      }
      // Home-row confirm looks like any other quiet move confirm.
      return (title: 'Moving…', subtitle: busyLine ?? 'Confirming…');
    }
    if (busyLine != null) return (title: busyLine, subtitle: null);
    if (snap != null &&
        snap.state == 'Created' &&
        rosterReady &&
        snap.bothSetups) {
      return (title: 'Starting match…', subtitle: null);
    }
    return null;
  }
}

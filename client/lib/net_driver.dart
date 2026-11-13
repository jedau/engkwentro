import 'dart:async';

import 'net_play.dart';

/// Keeps one [NetSession] in step with the chain.
///
/// There is exactly one writer. A background loop syncs and performs the
/// chores the match needs (start once both armies are locked, resolve a
/// fight, flip at the end, drop a flag), and user actions go through [run].
/// Both take the same lock, so two things never talk to NEAR for this match
/// at once and a slow reply can never overwrite a newer one.
///
/// The loop reschedules itself only after a step has finished, and every
/// network call underneath has a deadline, so it cannot overlap itself and
/// it cannot stall for good. No Flutter here: the same driver runs under
/// the two-phone simulation in `test/`.
class MatchDriver {
  /// [onChange] fires when the screen should repaint; [onError] gets a
  /// message to show. Repeats of the same background error are swallowed.
  MatchDriver(
    this.session, {
    this.onChange,
    this.onError,
    this.idleEvery = const Duration(seconds: 1),
    this.fastEvery = const Duration(milliseconds: 250),
    this.endedEvery = const Duration(seconds: 3),
    this.noteEvery = const Duration(milliseconds: 300),
  }) {
    session.onChange = _notify;
  }

  /// The match being driven.
  final NetSession session;

  /// Repaint hook.
  final void Function()? onChange;

  /// Error hook. Receives a display string.
  final void Function(String message)? onError;

  /// Gap between steps while it is this phone's turn to think.
  final Duration idleEvery;

  /// Gap between steps while something is expected from the chain: the
  /// opponent's move, a fight, a move in flight, the match starting.
  final Duration fastEvery;

  /// Gap between steps once the match has ended and armies are flipping.
  final Duration endedEvery;

  /// How often the mailbox is asked whether the opponent has tapped.
  final Duration noteEvery;

  Future<void> _tail = Future<void>.value();
  bool _running = false;
  bool _stopped = false;
  Timer? _next;
  Timer? _notes;
  bool _noteInFlight = false;
  String? _lastStepError;
  int _stepFailures = 0;

  /// Steps completed. For tests and diagnostics.
  int steps = 0;

  /// Starts the background loop once there is a match to follow. Safe to
  /// call more than once, and before the match exists: [run] calls it again.
  void start() {
    if (_running || _stopped || session.matchId == null) return;
    _running = true;
    _notes ??= Timer.periodic(noteEvery, (_) => _pollNote());
    unawaited(_loop());
  }

  /// Looks for the opponent's "I tapped" note. Not under the lock: it only
  /// reads the mailbox and only affects how their clock is drawn, so it
  /// must never wait behind, or hold up, anything that matters.
  Future<void> _pollNote() async {
    if (_stopped || _noteInFlight) return;
    final snap = session.play;
    if (snap == null || !snap.ticking || snap.toMove == session.sideLabel) {
      return;
    }
    _noteInFlight = true;
    try {
      await session.pollOpponentTap();
    } catch (_) {
      // The chain will say the same thing a moment later.
    } finally {
      _noteInFlight = false;
    }
  }

  /// Stops the loop for good. An in-flight step still finishes.
  void stop() {
    _stopped = true;
    _next?.cancel();
    _notes?.cancel();
    if (identical(session.onChange, _notify)) session.onChange = null;
  }

  void _notify() {
    if (!_stopped) onChange?.call();
  }

  /// Runs a user action, then brings the screen up to date.
  ///
  /// [NetSession.busy] is raised immediately so buttons disable on the same
  /// frame, even while a background step is still finishing.
  Future<void> run(Future<void> Function() action) async {
    if (_stopped) return;
    session.busy = true;
    _notify();
    try {
      await _exclusive(() async {
        try {
          await action();
        } finally {
          // Whatever happened, show what the chain says now.
          if (session.matchId != null) {
            try {
              await _step();
            } catch (_) {
              // The loop will retry and report.
            }
          }
        }
      });
      _lastStepError = null;
    } catch (e) {
      onError?.call(
        _transient(e) ? 'NEAR did not answer. Please try again.' : _message(e),
      );
    } finally {
      session.busy = false;
      _notify();
    }
    start();
  }

  /// Taps a move: commits to it on this frame, then submits it.
  ///
  /// The overlay is up and the clock is held before this returns its
  /// future; the transaction follows as soon as the lock is free.
  Future<void> move(int from, int to) async {
    if (!session.beginMove(from, to)) {
      _notify();
      return;
    }
    await run(session.submitMove);
  }

  Future<void> _loop() async {
    while (!_stopped) {
      try {
        await _exclusive(_step);
        _lastStepError = null;
        _stepFailures = 0;
      } catch (e) {
        // One slow reply is retried without comment. Say something only
        // when it keeps happening, and say it once.
        _stepFailures++;
        final message = _message(e);
        final worthSaying = !_transient(e) || _stepFailures >= 2;
        if (worthSaying && message != _lastStepError) {
          _lastStepError = message;
          onError?.call(message);
        }
      }
      _notify();
      if (_stopped || session.finished) {
        _notes?.cancel();
        _notes = null;
        break;
      }
      final gap = Completer<void>();
      _next = Timer(_gap(), gap.complete);
      await gap.future;
    }
    _running = false;
  }

  /// How long to wait before the next step.
  Duration _gap() {
    final s = session;
    final snap = s.play;
    if (snap == null) return fastEvery;
    if (snap.state == 'Ended') return endedEvery;
    if (s.pending != null || snap.waiting) return fastEvery;
    if (snap.state == 'Created') {
      return s.accepted && s.rosterReady ? fastEvery : idleEvery;
    }
    return snap.toMove == s.sideLabel ? idleEvery : fastEvery;
  }

  /// One sync, then at most one chore.
  Future<void> _step() async {
    final s = session;
    final snap = await s.refresh();
    steps++;
    // Fight copy belongs to a fight. Once the wait is over, nothing from it
    // may linger and hold the overlay up.
    if (!snap.waiting) s.progress = null;
    if (snap.state == 'Created') {
      if (s.accepted && s.rosterReady && snap.bothSetups) {
        await s.confirmRoster(silent: true);
      }
      return;
    }
    if (snap.waiting) {
      await s.resolveIfWaiting();
      await s.refresh();
      return;
    }
    if (snap.state == 'Ended') {
      await s.flipIfEnded();
      return;
    }
    if (s.sideToMoveTimedOut()) {
      await s.claimTimeout();
    }
  }

  /// Runs [body] after everything queued before it has finished.
  Future<T> _exclusive<T>(Future<T> Function() body) async {
    final before = _tail;
    final done = Completer<void>();
    _tail = done.future;
    try {
      await before;
      return await body();
    } finally {
      done.complete();
    }
  }

  /// True for a timeout or dropped connection: nothing is wrong with the
  /// match, the network just did not answer.
  static bool _transient(Object e) {
    if (e is TimeoutException) return true;
    final text = e.toString();
    return text.contains('network error') || text.contains('timed out');
  }

  static String _message(Object e) {
    if (_transient(e)) return 'Connection is slow. Still trying…';
    final text = e.toString();
    for (final prefix in const ['Bad state: ', 'Exception: ']) {
      if (text.startsWith(prefix)) return text.substring(prefix.length);
    }
    return text;
  }
}

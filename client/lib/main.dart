import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'arbiter.g.dart';
import 'auth.dart';
import 'board_layout.dart';
import 'game.dart';
import 'net_page.dart';
import 'net_play.dart';
import 'pixel_button.dart';
import 'session_boot.dart';
import 'stake.dart';
import 'theme.dart';
import 'wallet_chooser.dart';

/// Boots [EngkwentroApp].
void main() => runApp(const EngkwentroApp());

/// `/` is Create / Join. No local pass-and-play.
final _router = GoRouter(
  routes: [GoRoute(path: '/', builder: (_, _) => const HomePage())],
);

/// Dark Material app. Owns [AuthController].
class EngkwentroApp extends StatefulWidget {
  /// Root widget. [auth] is injected in tests.
  const EngkwentroApp({super.key, this.auth});

  /// Optional pre-built auth (tests). Null creates and [AuthController.init]s.
  final AuthController? auth;

  @override
  State<EngkwentroApp> createState() => _EngkwentroAppState();
}

class _EngkwentroAppState extends State<EngkwentroApp> {
  late final AuthController auth =
      widget.auth ?? AuthController.fromEnvironment();

  @override
  void initState() {
    super.initState();
    if (widget.auth == null) {
      auth.init();
    }
  }

  @override
  void dispose() {
    if (widget.auth == null) {
      auth.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AuthScope(
      auth: auth,
      child: MaterialApp.router(
        title: 'Engkwentro',
        theme: engkwentroTheme(),
        routerConfig: _router,
      ),
    );
  }
}

/// Provides [AuthController] below [EngkwentroApp].
class AuthScope extends InheritedNotifier<AuthController> {
  /// [auth] notifies on login / logout.
  const AuthScope({
    super.key,
    required AuthController auth,
    required super.child,
  }) : super(notifier: auth);

  /// Nearest controller.
  static AuthController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AuthScope>();
    assert(scope != null, 'AuthScope missing');
    return scope!.notifier!;
  }
}

/// Create match or join match. Always two devices.
class HomePage extends StatefulWidget {
  /// [config] is injected in tests; the app reads auth / mailbox.
  const HomePage({super.key, this.config});

  /// Optional preloaded accounts. Null means [AuthController.configFor].
  final NetConfig? config;

  /// Creates [_HomePageState].
  @override
  State<HomePage> createState() => _HomePageState();
}

/// Home buttons open modals; the match screen opens only after success.
class _HomePageState extends State<HomePage> {
  /// Live session after create or join. Null stays on home.
  NetSession? match;

  /// Config used to open [match] (role, mailbox).
  NetConfig? matchConfig;

  NetConfig _base(bool roleA) {
    if (widget.config != null) {
      return widget.config!.copyWith(roleA: roleA, opponent: '');
    }
    return AuthScope.of(context).configFor(roleA: roleA);
  }

  /// Login sheet: in-app create, logo-first wallets, WC, demo mailbox.
  Future<void> _askLogin() async {
    final auth = AuthScope.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return WalletOnboardingSheet(
          auth: auth,
          onDone: () {
            if (ctx.mounted) Navigator.pop(ctx);
          },
        );
      },
    );
  }

  /// Ensures a session exists, then runs [fn].
  Future<void> _requireLogin(Future<void> Function() fn) async {
    final auth = AuthScope.of(context);
    if (!auth.isLoggedIn && widget.config == null) {
      await _askLogin();
      if (!auth.isLoggedIn || !mounted) return;
    }
    await fn();
  }

  /// Create modal → open challenge → match screen waiting for opponent.
  Future<void> _askCreate() => _requireLogin(() async {
    final choices = await showDialog<CreateMatchChoices>(
      context: context,
      builder: (_) => const _CreateMatchDialog(),
    );
    if (!mounted || choices == null) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('Creating match…')),
          ],
        ),
      ),
    );

    try {
      final session = await createOpenMatch(
        _base(true),
        clockMinutes: choices.clockMinutes,
        stakeYocto: choices.stake.yocto,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      setState(() {
        match = session;
        matchConfig = _base(true);
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not create'),
          content: Text('$e'),
          actions: [
            PixelButton(
              label: 'OK',
              compact: true,
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
    }
  });

  /// Join / rejoin modal: key or match id; creator and opponent both resume.
  Future<void> _askJoin() => _requireLogin(() async {
    final key = await showDialog<String>(
      context: context,
      builder: (_) => const _JoinKeyDialog(),
    );
    if (!mounted || key == null || key.trim().isEmpty) return;
    await _enterMatch(key);
  });

  /// Boots a session for [raw] (join key or numeric id) and opens the board.
  Future<void> _enterMatch(String raw) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('Joining match…')),
          ],
        ),
      ),
    );

    try {
      final session = await resumeMatch(_base(true), raw);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      setState(() {
        match = session;
        matchConfig = _base(session.sideA);
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not join'),
          content: Text('$e'),
          actions: [
            PixelButton(
              label: 'OK',
              compact: true,
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
    }
  }

  /// Match screen after a successful create or join.
  @override
  Widget build(BuildContext context) {
    final live = match;
    final cfg = matchConfig;
    if (live != null && cfg != null) {
      return NetPlayPage(
        config: cfg,
        ready: live,
        onExit: () => setState(() {
          match = null;
          matchConfig = null;
        }),
      );
    }

    final auth = AuthScope.of(context);
    final session = auth.session;
    final playReady = auth.isLoggedIn;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final logoHeight = (constraints.maxHeight * 0.26).clamp(
              120.0,
              240.0,
            );
            return Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Image.asset(
                          'assets/images/engkwentro-logo.png',
                          key: const ValueKey('brand-logo'),
                          width: double.infinity,
                          height: logoHeight,
                          fit: BoxFit.contain,
                          semanticLabel: 'Engkwentro',
                        ),
                        const SizedBox(height: 24),
                        if (session != null) ...[
                          Text(
                            session.accountId,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            switch (session.source) {
                              AuthSource.wallet => 'NEAR wallet',
                              AuthSource.local => 'Play account',
                              AuthSource.walletConnect => 'WalletConnect',
                              AuthSource.demo => 'Testnet demo account',
                            },
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (!playReady)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'Create a play account to submit moves.',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          if (session.source == AuthSource.local &&
                              session.canSignLocally)
                            PixelTextButton(
                              label: 'Export private key',
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: session.privateKey),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Private key copied — import it into a '
                                      'NEAR wallet to use this account elsewhere',
                                    ),
                                  ),
                                );
                              },
                            ),
                          PixelTextButton(
                            label: 'Log out',
                            onPressed: auth.logout,
                          ),
                        ] else
                          PixelButton(
                            key: const ValueKey('connect-wallet'),
                            label: 'Connect',
                            trailingLabel: 'Wallet',
                            leading: Image.asset(
                              'assets/images/near-logo.png',
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.medium,
                            ),
                            onPressed: _askLogin,
                          ),
                        if (playReady) ...[
                          const SizedBox(height: 16),
                          PixelButton(
                            label: 'Create match',
                            onPressed: _askCreate,
                          ),
                          const SizedBox(height: 12),
                          PixelButton(
                            label: 'Join match',
                            variant: PixelButtonVariant.secondary,
                            onPressed: _askJoin,
                          ),
                        ] else if (session != null) ...[
                          const SizedBox(height: 16),
                          PixelButton(
                            label: 'Create play account',
                            onPressed: _askLogin,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// `/play` route wrapper around [PlayView].
class PlayPage extends StatelessWidget {
  /// Routed local match.
  const PlayPage({super.key});

  /// Hands [PlayView.onExit] to `context.go('/')`.
  @override
  Widget build(BuildContext context) {
    return PlayView(onExit: () => context.go('/'));
  }
}

/// Pass-and-play. Hand the device; fog hides the other army.
class PlayView extends StatefulWidget {
  /// [onExit] is the app-bar back action.
  const PlayView({super.key, required this.onExit});

  /// Leave the local match.
  final VoidCallback onExit;

  /// Creates [_PlayViewState].
  @override
  State<PlayView> createState() => _PlayViewState();
}

/// Local match: hand-off, tap-to-move, resign, reset.
class _PlayViewState extends State<PlayView> {
  MatchGame game = MatchGame.standard();
  bool handed = false;

  /// Reveals [MatchGame.toMove]'s ranks after the device is handed over.
  void _handOff() {
    setState(() {
      game.viewer = game.toMove;
      handed = true;
    });
  }

  /// Select-then-move while [handed] and the match is live.
  void _tap(int s) {
    if (!handed || game.result != null) return;
    setState(() {
      if (game.selected == null) {
        final p = game.board[s];
        if (p != null && p.side == game.toMove) game.selected = s;
        return;
      }
      if (game.selected == s) {
        game.selected = null;
        return;
      }
      game.play(game.selected!, s);
      game.selected = null;
      if (game.result == null) handed = false;
    });
  }

  /// Status, hand-off / resign, snug board.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Engkwentro'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onExit,
        ),
        actions: [
          PixelTextButton(
            label: 'Reset',
            onPressed: () => setState(() {
              game = MatchGame.standard();
              handed = false;
            }),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                children: [
                  Text(
                    game.result ??
                        (handed
                            ? 'Player ${game.toMove == Side.a ? 'A' : 'B'} to move'
                            : 'Pass the device to Player ${game.toMove == Side.a ? 'A' : 'B'}'),
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  Text(game.log, textAlign: TextAlign.center),
                  if (!handed && game.result == null)
                    PixelButton(
                      label: 'I am this player',
                      onPressed: _handOff,
                      compact: true,
                    ),
                  if (handed && game.result == null)
                    PixelTextButton(
                      label: 'Resign',
                      onPressed: () => setState(() => game.resign(game.toMove)),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _Board(game: game, enabled: handed, onTap: _tap),
            ),
          ],
        ),
      ),
    );
  }
}

/// Snug 9×8 local board. No file/rank gutters.
class _Board extends StatelessWidget {
  /// [onTap] receives a wire square 0–71.
  const _Board({
    required this.game,
    required this.enabled,
    required this.onTap,
  });

  /// Local engine.
  final MatchGame game;

  /// False until hand-off, so the next player does not peek.
  final bool enabled;

  /// Square tap.
  final void Function(int) onTap;

  /// Width-first square cells via [snugBoardSize].
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = snugBoardSize(box);
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 9,
              ),
              itemCount: 72,
              itemBuilder: (context, i) {
                final file = i % 9;
                final rank = 7 - i ~/ 9;
                return _Square(
                  game: game,
                  square: MatchGame.sq(file, rank),
                  enabled: enabled,
                  onTap: onTap,
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// One local cell. Own ranks, enemy discs.
class _Square extends StatelessWidget {
  /// [square] is the wire index, not the GridView index.
  const _Square({
    required this.game,
    required this.square,
    required this.enabled,
    required this.onTap,
  });

  /// Local engine.
  final MatchGame game;

  /// Wire square 0–71.
  final int square;

  /// Whether taps select or move.
  final bool enabled;

  /// Square tap.
  final void Function(int) onTap;

  /// Paints home-row tint, selection, rank or disc.
  @override
  Widget build(BuildContext context) {
    final p = game.board[square];
    final selected = game.selected == square;
    final dark = (MatchGame.fileOf(square) + MatchGame.rankOf(square)) % 2 == 0;
    final homeA = MatchGame.homeA.contains(MatchGame.rankOf(square));
    final homeB = MatchGame.homeB.contains(MatchGame.rankOf(square));
    Color fill = dark
        ? EngkwentroColors.boardDark
        : EngkwentroColors.boardLight;
    if (homeA) fill = Color.lerp(fill, EngkwentroColors.gold, 0.16)!;
    if (homeB) fill = Color.lerp(fill, EngkwentroColors.tan, 0.16)!;
    if (selected) fill = EngkwentroColors.gold;

    String label = '';
    Color ink = selected ? EngkwentroColors.ink : EngkwentroColors.cream;
    if (p != null) {
      if (!enabled || !game.visible(square)) {
        label = '●';
        ink = selected
            ? EngkwentroColors.ink
            : (p.side == Side.a
                  ? EngkwentroColors.cream
                  : EngkwentroColors.tan);
      } else {
        label = rankNames[p.rank.index];
        ink = selected
            ? EngkwentroColors.ink
            : (p.side == Side.a
                  ? EngkwentroColors.cream
                  : EngkwentroColors.sand);
      }
    }

    return Material(
      color: fill,
      child: InkWell(
        onTap: enabled ? () => onTap(square) : null,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: EngkwentroColors.ink.withValues(alpha: 0.65),
              width: 0.4,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Create dialog with clock bank + optional stake pot.
class _CreateMatchDialog extends StatefulWidget {
  const _CreateMatchDialog();

  @override
  State<_CreateMatchDialog> createState() => _CreateMatchDialogState();
}

class _CreateMatchDialogState extends State<_CreateMatchDialog> {
  int _minutes = 15;
  final _stakeCtrl = TextEditingController(text: '0');

  @override
  void dispose() {
    _stakeCtrl.dispose();
    super.dispose();
  }

  StakeOption? get _parsedStake => stakeFromNearText(_stakeCtrl.text);

  void _submit() {
    final stake = _parsedStake;
    if (stake == null) return;
    Navigator.pop(
      context,
      CreateMatchChoices(clockMinutes: _minutes, stake: stake),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stake = _parsedStake;
    final caption = stake == null
        ? 'Enter a non-negative NEAR amount (e.g. 0 or 0.1).'
        : stakePayoutCaption(stake.yocto);

    return AlertDialog(
      title: const Text('Create match'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Creates an open challenge on testnet. You get a 12-character key '
              'to share. First mover is set when the opponent accepts — not '
              'always the creator.',
            ),
            const SizedBox(height: 16),
            Text(
              'Clock per player (in minutes)',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: _minutes <= 1
                      ? null
                      : () => setState(() => _minutes--),
                  icon: const Icon(Icons.remove),
                  tooltip: 'Fewer minutes',
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    '$_minutes',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: _minutes >= 15
                      ? null
                      : () => setState(() => _minutes++),
                  icon: const Icon(Icons.add),
                  tooltip: 'More minutes',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Stake (NEAR, each player)',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'Both players lock this amount. Setting 0 does not wager '
              'anything.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _stakeCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'NEAR',
                hintText: '0',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Text(
              caption,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: stake == null
                    ? EngkwentroColors.brown
                    : EngkwentroColors.gold,
              ),
            ),
          ],
        ),
      ),
      actions: [
        PixelTextButton(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        PixelButton(
          label: 'Create',
          compact: true,
          onPressed: stake == null ? null : _submit,
        ),
      ],
    );
  }
}

/// Join dialog owning its key controller so dismissal cannot dispose early.
class _JoinKeyDialog extends StatefulWidget {
  const _JoinKeyDialog();

  @override
  State<_JoinKeyDialog> createState() => _JoinKeyDialogState();
}

class _JoinKeyDialogState extends State<_JoinKeyDialog> {
  final _key = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  /// Pops the dialog with the entered key when [submit] is true.
  void _close({bool submit = false}) {
    Navigator.pop(context, submit ? _key.text : null);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join match'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Paste the 12-character match key, or the numeric match id. '
            'Creator and opponent can both rejoin after a disconnect.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Match key or id',
              hintText: 'XXXX-XXXX-XXXX',
            ),
            onSubmitted: (_) => _close(submit: true),
          ),
        ],
      ),
      actions: [
        PixelTextButton(label: 'Cancel', onPressed: () => _close()),
        PixelButton(
          label: 'Enter',
          compact: true,
          onPressed: () => _close(submit: true),
        ),
      ],
    );
  }
}

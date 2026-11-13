import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import 'arbiter.g.dart';
import 'board_layout.dart';
import 'game.dart';
import 'join_key.dart';
import 'mailbox.dart';
import 'near.dart';
import 'net_driver.dart';
import 'net_play.dart';
import 'pieces.dart';
import 'pixel_button.dart';
import 'stake.dart';
import 'theme.dart';

/// One row in the piece-legend dialog.
class _LegendEntry {
  const _LegendEntry(this.rank, this.name);
  final Rank rank;
  final String name;
}

/// Strongest officers first, then Spy / Private / Flag.
const _legendOrder = <_LegendEntry>[
  _LegendEntry(Rank.fiveStarGeneral, 'Five-star General'),
  _LegendEntry(Rank.general, 'Four-star General'),
  _LegendEntry(Rank.lieutenantGeneral, 'Three-star General'),
  _LegendEntry(Rank.majorGeneral, 'Two-star General'),
  _LegendEntry(Rank.brigadierGeneral, 'One-star General'),
  _LegendEntry(Rank.colonel, 'Colonel'),
  _LegendEntry(Rank.lieutenantColonel, 'Lieutenant Colonel'),
  _LegendEntry(Rank.major, 'Major'),
  _LegendEntry(Rank.captain, 'Captain'),
  _LegendEntry(Rank.firstLieutenant, 'First Lieutenant'),
  _LegendEntry(Rank.secondLieutenant, 'Second Lieutenant'),
  _LegendEntry(Rank.sergeant, 'Sergeant'),
  _LegendEntry(Rank.spy, 'Spy'),
  _LegendEntry(Rank.private, 'Private'),
  _LegendEntry(Rank.flag, 'Flag'),
];

/// Compile-time and mailbox-served config for a two-phone match.
class NetConfig {
  /// All fields are required; use [fromEnvironment] or [withMailboxCreds].
  const NetConfig({
    required this.roleA,
    required this.account,
    required this.key,
    required this.opponent,
    required this.contract,
    required this.rpc,
    required this.mailbox,
  });

  /// True if this phone is Alice.
  final bool roleA;

  /// NEAR account id.
  final String account;

  /// `ed25519:` private key.
  final String key;

  /// Named opponent for `create_match`.
  final String opponent;

  /// Match contract id.
  final String contract;

  /// Preferred JSON-RPC URL.
  final String rpc;

  /// Mailbox origin, no trailing slash.
  final String mailbox;

  /// Reads `--dart-define` values. Empty keys are filled by [withMailboxCreds].
  static NetConfig fromEnvironment() {
    const role = String.fromEnvironment('PLAYER_ROLE', defaultValue: 'A');
    return NetConfig(
      roleA: role != 'B',
      account: const String.fromEnvironment('PLAYER_ACCOUNT'),
      key: const String.fromEnvironment('PLAYER_KEY'),
      opponent: const String.fromEnvironment('OPPONENT_ACCOUNT'),
      contract: const String.fromEnvironment(
        'MATCH_CONTRACT',
        defaultValue: 'play.engkwentro.testnet',
      ),
      rpc: const String.fromEnvironment(
        'NEAR_RPC',
        defaultValue: 'https://rpc.testnet.fastnear.com',
      ),
      mailbox: const String.fromEnvironment(
        'MAILBOX_URL',
        defaultValue: 'http://127.0.0.1:8787',
      ),
    );
  }

  /// Same config with [roleA] set from the home button.
  NetConfig withRole(bool roleA) => copyWith(roleA: roleA);

  /// Overlay signed-in fields. Empty [opponent] is an open challenge.
  NetConfig copyWith({
    bool? roleA,
    String? account,
    String? key,
    String? opponent,
    String? contract,
    String? rpc,
    String? mailbox,
  }) => NetConfig(
    roleA: roleA ?? this.roleA,
    account: account ?? this.account,
    key: key ?? this.key,
    opponent: opponent ?? this.opponent,
    contract: contract ?? this.contract,
    rpc: rpc ?? this.rpc,
    mailbox: mailbox ?? this.mailbox,
  );

  /// True when a keypair is present. Opponent may be empty (open match).
  bool get ready => account.isNotEmpty && key.isNotEmpty;

  /// Fills empty keys from `GET {mailbox}/dev/cred?role=A|B`.
  Future<NetConfig> withMailboxCreds() async {
    if (ready) return this;
    late final http.Response res;
    try {
      res = await http.get(
        Uri.parse('$mailbox/dev/cred?role=${roleA ? 'A' : 'B'}'),
      );
    } catch (e) {
      throw StateError(
        'Mailbox not reachable at $mailbox. Start it with: '
        'node scripts/mailbox_local.mjs',
      );
    }
    if (res.statusCode >= 400) {
      throw StateError('Mailbox ${res.statusCode}: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return NetConfig(
      roleA: roleA,
      account: body['account'] as String,
      key: body['private_key'] as String,
      opponent: body['opponent'] as String,
      contract: contract,
      rpc: rpc,
      mailbox: mailbox,
    );
  }
}

/// Lobby then match. Create / join stay off the board.
class NetPlayPage extends StatefulWidget {
  /// [config] may have empty keys; they load from the mailbox on boot.
  const NetPlayPage({
    super.key,
    required this.onExit,
    required this.config,
    this.autoCreate = false,
    this.autoJoinKey,
    this.ready,
  });

  /// Back to home.
  final VoidCallback onExit;

  /// Role, RPC, mailbox, and optional keys.
  final NetConfig config;

  /// True when opened from **Create match** — submits after sign-in.
  final bool autoCreate;

  /// Key from the home join dialog. Accepts after sign-in.
  final String? autoJoinKey;

  /// Session that already created or joined. Skips the lobby.
  final NetSession? ready;

  /// Creates [_NetPlayPageState].
  @override
  State<NetPlayPage> createState() => _NetPlayPageState();
}

/// Signs in, then lobby or match. A [MatchDriver] keeps the match in step.
///
/// This widget holds no match state of its own: everything it paints comes
/// from [NetSession.play], the last row the driver applied.
class _NetPlayPageState extends State<NetPlayPage> {
  NetSession? session;
  MatchDriver? driver;
  Timer? clockTick;
  String? error;
  String boot = 'Signing in…';

  /// Starts [_boot], or resumes a [ready] session that already created/joined.
  @override
  void initState() {
    super.initState();
    // Repaints the running clock between syncs. Paints only; no network.
    clockTick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final s = session;
      if (s != null && _showClocks(s)) setState(() {});
    });
    final ready = widget.ready;
    if (ready != null) {
      boot = 'Signed in as ${ready.me}.';
      _attach(ready);
      if (ready.matchId == null) _boot();
    } else {
      _boot();
    }
  }

  /// Puts [s] on screen and starts driving it.
  void _attach(NetSession s) {
    driver?.stop();
    session = s;
    driver = MatchDriver(
      s,
      onChange: () {
        if (mounted) setState(() {});
      },
      onError: _showError,
    )..start();
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => error = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Loads keys, builds [NetSession]. Does not create a match.
  Future<void> _boot() async {
    try {
      var s = session;
      if (s == null) {
        final cfg = widget.config.ready
            ? widget.config
            : await widget.config.withMailboxCreds();
        if (!mounted) return;
        s = NetSession(
          near: NearClient(
            rpcUrl: cfg.rpc,
            accountId: cfg.account,
            privateKey: cfg.key,
            contractId: cfg.contract,
          ),
          mailbox: Mailbox(cfg.mailbox),
          sideA: cfg.roleA,
          opponent: cfg.opponent,
        )..log = 'Signed in as ${cfg.account}.';
        setState(() => _attach(s!));
      }
      final live = s;
      if (widget.autoCreate) {
        await _run(live.create);
      } else if (widget.autoJoinKey != null) {
        await _run(() => live.acceptKey(widget.autoJoinKey!));
      }
    } catch (e) {
      if (mounted) setState(() => boot = 'Could not load keys: $e');
    }
  }

  /// Stops the driver and the repaint timer.
  @override
  void dispose() {
    driver?.stop();
    clockTick?.cancel();
    super.dispose();
  }

  /// Runs a user action through the driver, one at a time.
  Future<void> _run(Future<void> Function() fn) async {
    final d = driver;
    if (d == null || d.session.busy) return;
    setState(() => error = null);
    await d.run(fn);
  }

  final GlobalKey _shareButtonKey = GlobalKey();

  /// Opens the system share sheet for the match key (Messages, copy, etc.).
  ///
  /// Falls back to copying the key if the sheet fails (common after a hot
  /// reload without a full restart, or when the plugin is not linked yet).
  Future<void> _shareKey(NetSession s) async {
    final key = s.joinKey;
    if (key == null || key.isEmpty) return;
    final formatted = formatJoinKey(key);
    final box =
        _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: formatted,
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      await Clipboard.setData(ClipboardData(text: formatted));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Match key copied: $formatted')),
      );
    }
  }

  /// Sets up an own-home square, or selects then moves an occupancy square.
  void _tap(int s) {
    final game = session;
    final d = driver;
    if (game == null || d == null) return;
    if (game.settingUp) {
      setState(() => game.setupTap(s));
      return;
    }
    if (!game.canAct) return;
    if (game.selected == null) {
      if (game.mine(game.occupancy[s])) setState(() => game.selected = s);
      return;
    }
    if (game.selected == s) {
      setState(() => game.selected = null);
      return;
    }
    // Retarget onto another of our pieces instead of submitting.
    if (game.mine(game.occupancy[s])) {
      setState(() => game.selected = s);
      return;
    }
    final from = game.selected!;
    if (!game.canMove(from, s)) {
      game.log = 'Illegal move — only an adjacent empty or enemy square.';
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Illegal move — one step to an empty or enemy square.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    // From this frame the turn is no longer ours: overlay up, clock held.
    unawaited(d.move(from, s));
  }

  /// Signing-in or match. Create / join modals live on home.
  @override
  Widget build(BuildContext context) {
    final cfg = widget.config;
    final s = session;
    if (s == null || s.matchId == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(cfg.roleA ? 'Create match' : 'Join match'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: widget.onExit,
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(error ?? boot, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    return _match(context, cfg, s);
  }

  /// Second line under the setup CTA (first-mover), or null.
  String? _statusSublabel(NetSession s) {
    if (!s.settingUp || s.first == null) return null;
    return s.iAmLight ? 'You will move first' : 'Opponent will move first';
  }

  /// Rank tray, auto-fill/clear, and confirm for the setup phase.
  Widget _setupPanel(BuildContext context, NetSession s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.setupRemaining == 0
              ? 'Army ready. Confirm to lock it.'
              : 'Tap a piece, then a gold-outlined home square.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final rank in Rank.values)
                if (s.setupCount(rank) > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      onTap: () => setState(() => s.selectSetupRank(rank)),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: s.setupSelected == rank
                                ? EngkwentroColors.gold
                                : EngkwentroColors.ink.withValues(alpha: 0.4),
                            width: s.setupSelected == rank ? 3 : 2,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PieceArt(rank: rank, light: s.iAmLight, size: 52),
                            Text(
                              '×${s.setupCount(rank)}',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
        Row(
          children: [
            PixelTextButton(
              label: 'Auto-fill',
              onPressed: s.busy ? null : () => setState(s.setupAutoFill),
            ),
            PixelTextButton(
              label: 'Clear',
              onPressed: s.busy ? null : () => setState(s.setupClear),
            ),
            const Spacer(),
            Flexible(
              child: PixelButton(
                label: 'Confirm',
                compact: true,
                onPressed: s.setupRemaining == 0 && !s.busy
                    ? () => _confirmRoster(s)
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Warns that placement is final, then locks and kicks off when both ready.
  Future<void> _confirmRoster(NetSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm roster?'),
        content: const Text(
          "You can't change the placement once you confirm.",
        ),
        actions: [
          PixelTextButton(
            label: 'Cancel',
            onPressed: () => Navigator.pop(ctx, false),
          ),
          PixelButton(
            label: 'Confirm',
            compact: true,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok == true) await _run(s.confirmRoster);
  }

  /// Commit / confirm / resign plus the snug occupancy board.
  ///
  /// Before the opponent joins, the body is an invite (key + Share), not the
  /// empty board. After join, home ranks stay on the lower half.
  Widget _match(BuildContext context, NetConfig cfg, NetSession s) {
    final activity = s.activity();
    final snap = s.play;
    final waiting = !s.accepted;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          waiting
              ? 'New match'
              : (s.joinKey != null ? formatJoinKey(s.joinKey!) : 'Match'),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onExit,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Piece legend',
            onPressed: () => _showLegend(s),
          ),
          if (s.joinKey != null && !waiting)
            IconButton(
              key: _shareButtonKey,
              icon: const Icon(Icons.ios_share),
              tooltip: 'Share match key',
              onPressed: () => _shareKey(s),
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            if (waiting)
              _inviteLobby(context, s)
            else
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    child: Column(
                      children: [
                        Text(
                          s.statusLine,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (_statusSublabel(s) != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            _statusSublabel(s)!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                        if (snap?.state == 'Ended') ...[
                          const SizedBox(height: 8),
                          Text(
                            s.endHeadline,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          if (s.endCause != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              s.endCause!,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(color: EngkwentroColors.sand),
                            ),
                          ],
                        ],
                        if (!s.settingUp &&
                            snap != null &&
                            snap.state != 'Ended' &&
                            snap.state != 'Created')
                          PixelTextButton(
                            label: 'Resign',
                            onPressed: s.busy ? null : () => _run(s.resign),
                          ),
                        if (s.hasStake &&
                            snap != null &&
                            snap.state != 'Ended') ...[
                          const SizedBox(height: 4),
                          Text(
                            formatPotYocto(s.stakeYocto),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ],
                        if (snap?.state == 'Ended' &&
                            s.hasStake &&
                            !s.payoutClaimed &&
                            (s.settlement == 'Settled' ||
                                s.settlement == 'Forfeited' ||
                                s.settlement == 'Voided')) ...[
                          const SizedBox(height: 8),
                          PixelButton(
                            label: 'Claim pot',
                            compact: true,
                            onPressed: s.busy
                                ? null
                                : () => _run(s.claimPayoutIfNeeded),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_showClocks(s))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: _clockRow(
                        context,
                        s,
                        mine: false,
                      ),
                    ),
                  Expanded(
                    child: _NetBoard(
                      session: s,
                      enabled: s.settingUp || s.canAct,
                      onTap: _tap,
                    ),
                  ),
                  if (_showClocks(s))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: _clockRow(
                        context,
                        s,
                        mine: true,
                      ),
                    ),
                  if (s.settingUp)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: _setupPanel(context, s),
                    )
                  else if (snap != null &&
                      snap.state != 'Created' &&
                      s.rosterReady)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: _graveyard(context, s),
                    ),
                ],
              ),
            if (activity != null)
              _ActivityModal(
                title: activity.title,
                subtitle: activity.subtitle,
              ),
          ],
        ),
      ),
    );
  }

  /// Rank ladder + specials for the current player's art set.
  Future<void> _showLegend(NetSession s) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Piece legend'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Higher officers beat lower ones. Spy beats every officer; '
                  'only a Private kills a Spy. Anyone captures the Flag.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: EngkwentroColors.sand,
                  ),
                ),
                const SizedBox(height: 12),
                for (final entry in _legendOrder)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        PieceArt(
                          rank: entry.rank,
                          light: s.iAmLight,
                          size: 36,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            entry.name,
                            style: Theme.of(ctx).textTheme.bodyMedium,
                          ),
                        ),
                        Text(
                          '×${composition[entry.rank] ?? 0}',
                          style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                            color: EngkwentroColors.gold,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          PixelButton(
            label: 'Close',
            compact: true,
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  /// Pre-join invite: key is the hero; Share is the one action.
  Widget _inviteLobby(BuildContext context, NetSession s) {
    final key = s.joinKey != null ? formatJoinKey(s.joinKey!) : '—';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Waiting for opponent',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Send them this match key.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (s.hasStake) ...[
            const SizedBox(height: 10),
            Text(
              '${formatPotYocto(s.stakeYocto)} · each locks '
              '${formatNearYocto(s.stakeYocto)}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ],
          const Spacer(flex: 2),
          // Emphasized key frame — border only, not a primary CTA face.
          DecoratedBox(
            decoration: BoxDecoration(
              color: EngkwentroColors.navyDeep,
              border: Border.all(color: EngkwentroColors.gold, width: 3),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: SelectableText(
                key,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: EngkwentroColors.gold,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          PixelButton(
            key: _shareButtonKey,
            label: 'Share match key',
            onPressed: () => _shareKey(s),
          ),
          const Spacer(flex: 3),
        ],
      ),
    );
  }

  /// Clocks once the roster is live, board is painted, and the match is not over.
  bool _showClocks(NetSession s) {
    final snap = s.play;
    if (snap == null) return false;
    if (s.occupancy.every((occ) => occ == 0)) return false;
    return snap.live || snap.waiting;
  }

  /// Opponent above the board (`mine: false`), you beneath (`mine: true`).
  Widget _clockRow(
    BuildContext context,
    NetSession s, {
    required bool mine,
  }) {
    final side = mine ? s.sideLabel : (s.sideA ? 'B' : 'A');
    // A clock is lit while it is running. It stops at the tap.
    final active = s.clockRunning(side);
    final label = mine ? 'You' : 'Opponent';
    final timeStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      color: active ? EngkwentroColors.ink : EngkwentroColors.cream,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const Spacer(),
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? EngkwentroColors.gold
                : EngkwentroColors.boardLight.withValues(alpha: 0.55),
            border: Border.all(
              color: active ? EngkwentroColors.ink : EngkwentroColors.cream,
              width: 2,
            ),
          ),
          child: Text(
            s.formatFor(side),
            style: timeStyle,
          ),
        ),
      ],
    );
  }

  /// Own fallen pieces only — opponent losses stay hidden.
  Widget _graveyard(BuildContext context, NetSession s) {
    final fallen = s.myGraveyard;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          fallen.isEmpty ? 'Graveyard' : 'Graveyard · ${fallen.length}',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          child: fallen.isEmpty
              ? Center(
                  child: Text(
                    'None fallen yet',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: EngkwentroColors.cream.withValues(alpha: 0.55),
                    ),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: fallen.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (_, i) => PieceArt(
                    rank: fallen[i],
                    light: s.iAmLight,
                    size: 40,
                  ),
                ),
        ),
      ],
    );
  }
}

/// Full-screen dimmer so NEAR / fight latency does not look like a hang.
class _ActivityModal extends StatelessWidget {
  /// Big [title] (e.g. `Battle!`); optional quiet [subtitle] under it.
  const _ActivityModal({required this.title, this.subtitle});

  /// Primary line — short and punchy.
  final String title;

  /// What is processing, or null when [title] is enough.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: EngkwentroColors.ink.withValues(alpha: 0.55),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: PixelPanel(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.headlineSmall,
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        subtitle!,
                        textAlign: TextAlign.center,
                        style: theme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Snug 9×8 occupancy grid. No file/rank numbers.
class _NetBoard extends StatelessWidget {
  /// [onTap] receives a wire square 0–71.
  const _NetBoard({
    required this.session,
    required this.enabled,
    required this.onTap,
  });

  /// Live occupancy and selection.
  final NetSession session;

  /// False while waiting for the opponent or a fight.
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
                final file = displayBoardFile(
                  i % 9,
                  sideA: session.sideA,
                );
                final rank = displayBoardRank(
                  i ~/ 9,
                  sideA: session.sideA,
                );
                return _NetSquare(
                  session: session,
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

/// One occupancy cell. Own ranks, enemy discs.
class _NetSquare extends StatelessWidget {
  /// [square] is the wire index, not the GridView index.
  const _NetSquare({
    required this.session,
    required this.square,
    required this.enabled,
    required this.onTap,
  });

  /// Occupancy source.
  final NetSession session;

  /// Wire square 0–71.
  final int square;

  /// Whether taps submit a move.
  final bool enabled;

  /// Square tap.
  final void Function(int) onTap;

  /// Paints home-row tint, selection, rank or disc.
  @override
  Widget build(BuildContext context) {
    final occ = square < session.occupancy.length
        ? session.occupancy[square]
        : 0;
    final setupRank = session.showSetupBoard
        ? session.setupRankAt(square)
        : null;
    final selected = session.selected == square;
    final dark = (MatchGame.fileOf(square) + MatchGame.rankOf(square)) % 2 == 0;
    Color fill = dark
        ? EngkwentroColors.boardDark
        : EngkwentroColors.boardLight;
    final myHome = session.sideA ? MatchGame.homeA : MatchGame.homeB;
    final theirHome = session.sideA ? MatchGame.homeB : MatchGame.homeA;
    if (myHome.contains(MatchGame.rankOf(square))) {
      fill = Color.lerp(fill, EngkwentroColors.gold, 0.16)!;
    }
    if (theirHome.contains(MatchGame.rankOf(square))) {
      fill = Color.lerp(fill, EngkwentroColors.tan, 0.16)!;
    }
    if (selected) fill = EngkwentroColors.gold;

    Widget? art;
    if (setupRank != null) {
      art = PieceArt(rank: setupRank, light: session.iAmLight);
    } else if (occ != 0) {
      final rank = session.rankOfOcc(occ);
      art = PieceArt(rank: rank, light: session.occIsLight(occ));
    }

    final canPlace =
        session.settingUp &&
        setupRank == null &&
        session.setupHome(square) &&
        session.setupSelected != null;

    return Material(
      color: fill,
      child: InkWell(
        onTap: enabled ? () => onTap(square) : null,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: canPlace
                  ? EngkwentroColors.gold
                  : EngkwentroColors.ink.withValues(alpha: 0.65),
              width: canPlace ? 1.2 : 0.4,
            ),
          ),
          padding: art == null ? EdgeInsets.zero : const EdgeInsets.all(2),
          child: art,
        ),
      ),
    );
  }
}

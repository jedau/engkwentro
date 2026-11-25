import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth.dart';
import 'pixel_button.dart';
import 'theme.dart';
import 'wallet_connect_bridge.dart';
import 'wallet_registry.dart';

/// Full login / create / connect sheet content for [HomePage].
class WalletOnboardingSheet extends StatefulWidget {
  /// [auth] drives create + wallet connect; [onDone] closes the sheet.
  const WalletOnboardingSheet({
    super.key,
    required this.auth,
    required this.onDone,
  });

  /// App auth controller.
  final AuthController auth;

  /// Called after a play-ready session is established.
  final VoidCallback onDone;

  @override
  State<WalletOnboardingSheet> createState() => _WalletOnboardingSheetState();
}

class _WalletOnboardingSheetState extends State<WalletOnboardingSheet> {
  final _nameCtrl = TextEditingController();
  bool _creating = false;
  String? _createStatus;
  String? _createdAccountId;
  String? _createdKey;
  String? _banner;

  AuthController get auth => widget.auth;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _createAccount() async {
    setState(() {
      _creating = true;
      _createStatus = 'Generating keys…';
      _banner = null;
      _createdKey = null;
      _createdAccountId = null;
    });
    try {
      setState(() => _createStatus = 'Requesting testnet faucet…');
      final account = await auth.createLocalAccount(
        preferredName: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text,
      );
      // Stay on this sheet so the user can copy the key before continuing.
      setState(() {
        _createStatus = null;
        _createdAccountId = account.accountId;
        _createdKey = account.privateKey;
      });
    } catch (e) {
      setState(() {
        _banner = '$e';
        _createStatus = null;
      });
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copyCreatedKey() async {
    final key = _createdKey;
    if (key == null) return;
    await Clipboard.setData(ClipboardData(text: key));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Private key copied')));
  }

  Future<void> _onWallet(WalletEntry entry) async {
    setState(() => _banner = null);
    switch (entry.kind) {
      case WalletConnectKind.walletConnect:
        await _connectWalletConnect();
      case WalletConnectKind.nearConnect:
        await _connectNear(entry);
      case WalletConnectKind.externalLink:
        final url = entry.url;
        if (url == null) return;
        final uri = Uri.parse(url);
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          setState(() => _banner = 'Could not open $url');
        } else {
          setState(
            () => _banner =
                'Install ${entry.name}, then connect with WalletConnect '
                'or create a play account.',
          );
        }
    }
  }

  Future<void> _connectWalletConnect() async {
    final result = await openWalletConnectFlow(context);
    if (!mounted || result == null) return;
    if (result.ok) {
      auth.setWalletConnectIdentity(result.accountId!);
      setState(() {
        _banner =
            'WalletConnect linked ${result.accountId}. Create a play account '
            'on this device to submit moves (local key required).';
      });
    } else if (result.error != null) {
      setState(() => _banner = result.error);
    }
  }

  Future<void> _connectNear(WalletEntry entry) async {
    final w = auth.wallet;
    final option = entry.nearOption;
    if (w == null || option == null) {
      setState(() => _banner = 'Wallet SDK not ready.');
      return;
    }
    if (!entry.supportsTestnet) {
      setState(() => _banner = '${entry.name} is mainnet only.');
      return;
    }
    try {
      await w.connect(wallet: option);
      await auth.refreshWalletSession();
      if (auth.isLoggedIn && auth.session?.source == AuthSource.wallet) {
        widget.onDone();
      } else if (auth.bootError != null) {
        setState(() => _banner = auth.bootError);
      }
    } catch (e) {
      setState(() => _banner = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallets = WalletRegistry.forTestnet(includeMainnetOnly: true);
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        return SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 4,
              bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Connect Wallet',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  'New to NEAR? Create a play account on this device — funded '
                  'on testnet, ready in seconds. Or connect an existing wallet.',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: EngkwentroColors.sand),
                ),
                const SizedBox(height: 16),
                if (_createdKey != null && _createdAccountId != null) ...[
                  Text(
                    'Account ready — save your key',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  PixelPanel(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _createdAccountId!,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'This key lives only on this phone (secure storage). '
                          'Copy it now if you want to import the account into '
                          'a NEAR wallet (MyNearWallet / Intear / Meteor → '
                          'import private key). Engkwentro never shows a '
                          'seed phrase.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _createdKey!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 14,
                                color: EngkwentroColors.cream,
                              ),
                        ),
                        const SizedBox(height: 8),
                        PixelButton(
                          label: 'Copy private key',
                          compact: true,
                          onPressed: _copyCreatedKey,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  PixelButton(
                    label: 'Continue to play',
                    onPressed: widget.onDone,
                  ),
                ] else ...[
                  Text(
                    'Create play account',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameCtrl,
                    enabled: !_creating,
                    decoration: const InputDecoration(
                      labelText: 'Optional name',
                      // v0.1 is testnet-only; mainnet would append .near instead.
                      hintText: 'alice (testnet → alice.testnet)',
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _creating ? null : _createAccount(),
                  ),
                  const SizedBox(height: 10),
                  PixelButton(
                    label: _creating ? 'Creating…' : 'Create play account',
                    onPressed: _creating ? null : _createAccount,
                  ),
                  if (_createStatus != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _createStatus!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
                if (_banner != null) ...[
                  const SizedBox(height: 12),
                  PixelPanel(
                    padding: const EdgeInsets.all(12),
                    child: Text(_banner!),
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  'Or connect a wallet',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Logos first. WalletConnect is the primary option.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final entry in wallets)
                  _WalletTile(
                    entry: entry,
                    emphasized: entry.id == 'walletconnect',
                    onTap: () => _onWallet(entry),
                  ),
                const Divider(height: 28),
                Text(
                  'Two-phone testnet demo',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: PixelButton(
                        label: 'Demo Alice',
                        compact: true,
                        variant: PixelButtonVariant.secondary,
                        onPressed: () async {
                          await auth.loginDemo(roleA: true);
                          widget.onDone();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: PixelButton(
                        label: 'Demo Bob',
                        compact: true,
                        variant: PixelButtonVariant.secondary,
                        onPressed: () async {
                          await auth.loginDemo(roleA: false);
                          widget.onDone();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WalletTile extends StatelessWidget {
  const _WalletTile({
    required this.entry,
    required this.onTap,
    this.emphasized = false,
  });

  final WalletEntry entry;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final disabled = !entry.supportsTestnet;
    final tile = InkWell(
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: disabled ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              _WalletLogo(asset: entry.logoAsset, size: emphasized ? 48 : 40),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: emphasized
                            ? EngkwentroColors.gold
                            : EngkwentroColors.cream,
                      ),
                    ),
                    if (entry.subtitle != null)
                      Text(
                        entry.subtitle!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: EngkwentroColors.sand.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: emphasized
          ? PixelPanel(padding: EdgeInsets.zero, child: tile)
          : tile,
    );
  }
}

class _WalletLogo extends StatelessWidget {
  const _WalletLogo({required this.asset, required this.size});

  final String asset;
  final double size;

  @override
  Widget build(BuildContext context) {
    final child = asset.endsWith('.svg')
        ? SvgPicture.asset(
            asset,
            width: size,
            height: size,
            fit: BoxFit.contain,
          )
        : Image.asset(asset, width: size, height: size, fit: BoxFit.contain);
    return SizedBox(width: size, height: size, child: child);
  }
}

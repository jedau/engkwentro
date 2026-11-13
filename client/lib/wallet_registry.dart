import 'package:near_wallet_connect/near_wallet_connect.dart';

/// How tapping a [WalletEntry] should proceed.
enum WalletConnectKind {
  /// Reown / WalletConnect SignClient (near:testnet).
  walletConnect,

  /// Deep-link FC flow via [NearWalletController.connect].
  nearConnect,

  /// Open an install / wallet URL in the browser or store.
  externalLink,
}

/// One row in the logo-first wallet chooser.
class WalletEntry {
  /// [id] is stable; [logoAsset] is under `assets/images/wallets/`.
  const WalletEntry({
    required this.id,
    required this.name,
    required this.logoAsset,
    required this.kind,
    this.nearOption,
    this.url,
    this.supportsTestnet = true,
    this.subtitle,
  });

  /// Stable machine id (`walletconnect`, `intear`, …).
  final String id;

  /// Display name shown beside the logo.
  final String name;

  /// Bundled logo path.
  final String logoAsset;

  /// Connect strategy.
  final WalletConnectKind kind;

  /// Set when [kind] is [WalletConnectKind.nearConnect].
  final NearWalletOption? nearOption;

  /// Install or wallet homepage when [kind] is [WalletConnectKind.externalLink].
  final String? url;

  /// False hides or dims the entry on testnet.
  final bool supportsTestnet;

  /// Optional secondary line under the name.
  final String? subtitle;
}

/// Curated NEAR wallets for the Engkwentro connect sheet (testnet-first).
abstract final class WalletRegistry {
  static const _logo = 'assets/images/wallets';

  /// WalletConnect is always first among connect options.
  static const walletConnect = WalletEntry(
    id: 'walletconnect',
    name: 'WalletConnect',
    logoAsset: '$_logo/walletconnect.png',
    kind: WalletConnectKind.walletConnect,
    subtitle: 'Scan or open a NEAR wallet',
  );

  /// Full chooser list: WC first, then package + ecosystem wallets.
  static const List<WalletEntry> all = [
    walletConnect,
    WalletEntry(
      id: 'intear',
      name: 'Intear Wallet',
      logoAsset: '$_logo/intear.png',
      kind: WalletConnectKind.nearConnect,
      nearOption: NearWalletOption.intear,
      subtitle: 'Recommended — local play key',
    ),
    WalletEntry(
      id: 'meteor',
      name: 'Meteor Wallet',
      logoAsset: '$_logo/meteor.png',
      kind: WalletConnectKind.externalLink,
      url: 'https://meteorwallet.app',
      subtitle: 'Install, then use WalletConnect',
    ),
    WalletEntry(
      id: 'bitte',
      name: 'Bitte Wallet',
      logoAsset: '$_logo/bitte.svg',
      kind: WalletConnectKind.nearConnect,
      nearOption: NearWalletOption.bitte,
      subtitle: 'May need a play account for moves',
    ),
    WalletEntry(
      id: 'here',
      name: 'HERE Wallet',
      logoAsset: '$_logo/here.png',
      kind: WalletConnectKind.nearConnect,
      nearOption: NearWalletOption.here,
      subtitle: 'May need a play account for moves',
    ),
    WalletEntry(
      id: 'hot',
      name: 'HOT Wallet',
      logoAsset: '$_logo/hot.png',
      kind: WalletConnectKind.nearConnect,
      nearOption: NearWalletOption.hot,
      supportsTestnet: false,
      subtitle: 'Mainnet only',
    ),
    WalletEntry(
      id: 'nightly',
      name: 'Nightly',
      logoAsset: '$_logo/nightly.png',
      kind: WalletConnectKind.externalLink,
      url: 'https://nightly.app',
      subtitle: 'Install, then use WalletConnect',
    ),
    WalletEntry(
      id: 'sender',
      name: 'Sender',
      logoAsset: '$_logo/sender.png',
      kind: WalletConnectKind.externalLink,
      url: 'https://senderwallet.io',
      subtitle: 'Install, then use WalletConnect',
    ),
    WalletEntry(
      id: 'near-mobile',
      name: 'NEAR Mobile',
      logoAsset: '$_logo/near-mobile.png',
      kind: WalletConnectKind.externalLink,
      url: 'https://near.mobile',
      subtitle: 'Install, then use WalletConnect',
    ),
    WalletEntry(
      id: 'mynearwallet',
      name: 'MyNearWallet',
      logoAsset: '$_logo/mynearwallet.png',
      kind: WalletConnectKind.nearConnect,
      nearOption: NearWalletOption.myNearWallet,
      subtitle: 'Sunsets 31 Oct 2026',
    ),
  ];

  /// Entries shown on testnet (drops mainnet-only unless included for info).
  static List<WalletEntry> forTestnet({bool includeMainnetOnly = false}) => [
    for (final w in all)
      if (w.supportsTestnet || includeMainnetOnly) w,
  ];
}

import 'package:flutter/foundation.dart';
import 'package:near_wallet_connect/near_wallet_connect.dart';
import 'package:url_launcher/url_launcher.dart';

import 'local_account.dart';
import 'net_page.dart';

/// Deep-link scheme for MyNearWallet / Bitte callbacks.
const walletCallbackScheme = 'engkwentro';

/// Where a logged-in session came from.
enum AuthSource {
  /// Function-call key from a real NEAR wallet.
  wallet,

  /// In-app keypair funded by the testnet faucet.
  local,

  /// WalletConnect identity only (no local signing key).
  walletConnect,

  /// Mailbox `/dev/cred` for two-phone testnet demos.
  demo,
}

/// Signed-in player. Holds enough for [NetConfig] / [NearClient].
class AuthSession {
  /// [accountId] is the NEAR predecessor. [privateKey] is `ed25519:…` when
  /// local signing is available (empty for [AuthSource.walletConnect]).
  const AuthSession({
    required this.accountId,
    required this.privateKey,
    required this.source,
  });

  /// NEAR account id.
  final String accountId;

  /// Secret key string for local signing (may be empty for WC-only).
  final String privateKey;

  /// Wallet / local / demo provenance.
  final AuthSource source;

  /// True when [privateKey] can drive [NearClient].
  bool get canSignLocally => privateKey.isNotEmpty;
}

/// App-wide login: in-app create, NEAR wallet connect, WC, demo mailbox.
class AuthController extends ChangeNotifier {
  /// Builds the wallet controller for [contractId] on testnet.
  AuthController({
    this.contractId = 'play.engkwentro.testnet',
    this.rpc = 'https://rpc.testnet.fastnear.com',
    this.mailbox = 'http://127.0.0.1:8787',
    LocalAccountFactory? localAccounts,
  }) : _localAccounts = localAccounts ?? LocalAccountFactory();

  /// Reads `--dart-define` mailbox / RPC / contract (Android needs `10.0.2.2`).
  factory AuthController.fromEnvironment() {
    final env = NetConfig.fromEnvironment();
    return AuthController(
      contractId: env.contract,
      rpc: env.rpc,
      mailbox: env.mailbox,
    );
  }

  /// Widget tests: already ready, optional [session], no wallet SDK.
  factory AuthController.forTest({
    AuthSession? session,
    LocalAccountFactory? localAccounts,
  }) {
    final a = AuthController(localAccounts: localAccounts);
    a._ready = true;
    a._session = session;
    return a;
  }

  /// Match contract the FC key is scoped to.
  final String contractId;

  /// Preferred JSON-RPC.
  final String rpc;

  /// Local mailbox origin for demo creds.
  final String mailbox;

  final LocalAccountFactory _localAccounts;

  NearWalletController? _wallet;
  AuthSession? _session;
  String? _bootError;
  bool _ready = false;

  /// Last WalletConnect account id (identity only), if any.
  String? walletConnectAccountId;

  /// Wallet SDK controller. Null until [init] finishes.
  NearWalletController? get wallet => _wallet;

  /// Current player, or null when logged out.
  AuthSession? get session => _session;

  /// True after [init].
  bool get ready => _ready;

  /// Last init / connect error for the UI.
  String? get bootError => _bootError;

  /// Shorthand for a play-ready session (local signing key present).
  bool get isLoggedIn => _session != null && _session!.canSignLocally;

  /// Restores local + wallet sessions and wires deep links.
  Future<void> init() async {
    try {
      final local = await _localAccounts.restore();
      if (local != null) {
        _session = AuthSession(
          accountId: local.accountId,
          privateKey: local.privateKey,
          source: AuthSource.local,
        );
      }

      final w = NearWalletController(
        network: MyNearWalletNetwork.testnet,
        contractId: AccountId(contractId),
        methodNames: const [],
        callbackScheme: walletCallbackScheme,
      );
      await w.init();
      w.addListener(_onWallet);
      _wallet = w;
      // Prefer an existing local play account over overwriting with wallet.
      if (_session == null || _session!.source != AuthSource.local) {
        await _pullWalletSession();
      }
      _bootError = null;
    } catch (e) {
      _bootError = '$e';
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  void _onWallet() {
    _pullWalletSession().then((_) => notifyListeners());
  }

  /// Copies a connected wallet into [_session] when a local key exists.
  Future<void> refreshWalletSession() async {
    final w = _wallet;
    if (w == null || !w.isConnected) {
      notifyListeners();
      return;
    }
    final account = await w.signer();
    if (account == null) {
      _bootError =
          'Wallet connected but no local key. Create a play account or use '
          'Intear / MyNearWallet.';
      notifyListeners();
      return;
    }
    _session = AuthSession(
      accountId: account.accountId.value,
      privateKey: account.keyPair.toString(),
      source: AuthSource.wallet,
    );
    _bootError = null;
    notifyListeners();
  }

  Future<void> _pullWalletSession() => refreshWalletSession();

  /// In-app keygen + testnet faucet → play-ready [AuthSession].
  Future<LocalAccount> createLocalAccount({String? preferredName}) async {
    final account = await _localAccounts.create(preferredName: preferredName);
    _session = AuthSession(
      accountId: account.accountId,
      privateKey: account.privateKey,
      source: AuthSource.local,
    );
    _bootError = null;
    notifyListeners();
    return account;
  }

  /// Records a WalletConnect identity without enabling local signing.
  void setWalletConnectIdentity(String accountId) {
    walletConnectAccountId = accountId;
    // Do not replace a play-ready local/wallet session.
    if (_session == null || !_session!.canSignLocally) {
      _session = AuthSession(
        accountId: accountId,
        privateKey: '',
        source: AuthSource.walletConnect,
      );
    }
    _bootError = 'WalletConnect linked. Create a play account to submit moves.';
    notifyListeners();
  }

  /// Opens NEAR Auth docs (legacy; prefer in-app create).
  Future<void> openFastAuthInfo() async {
    final uri = Uri.parse('https://docs.auth.near.org/');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open $uri');
    }
  }

  /// Loads Alice or Bob from the local mailbox for two-phone demos.
  Future<void> loginDemo({required bool roleA}) async {
    final cfg = await NetConfig(
      roleA: roleA,
      account: '',
      key: '',
      opponent: '',
      contract: contractId,
      rpc: rpc,
      mailbox: mailbox,
    ).withMailboxCreds();
    _session = AuthSession(
      accountId: cfg.account,
      privateKey: cfg.key,
      source: AuthSource.demo,
    );
    notifyListeners();
  }

  /// Clears wallet, local secure storage, and demo session.
  Future<void> logout() async {
    final w = _wallet;
    if (w != null && w.isConnected) {
      await w.disconnect();
    }
    if (_session?.source == AuthSource.local) {
      await _localAccounts.clear();
    }
    walletConnectAccountId = null;
    _session = null;
    _bootError = null;
    notifyListeners();
  }

  /// [NetConfig] for create/join using the logged-in key.
  NetConfig configFor({required bool roleA}) {
    final s = _session;
    if (s == null || !s.canSignLocally) {
      throw StateError('Log in with a play account or wallet first.');
    }
    return NetConfig(
      roleA: roleA,
      account: s.accountId,
      key: s.privateKey,
      opponent: '',
      contract: contractId,
      rpc: rpc,
      mailbox: mailbox,
    );
  }

  @override
  void dispose() {
    _wallet?.removeListener(_onWallet);
    _wallet?.dispose();
    super.dispose();
  }
}

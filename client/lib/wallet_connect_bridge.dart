import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'pixel_button.dart';
import 'theme.dart';

/// `--dart-define=REOWN_PROJECT_ID=…` from Reown Cloud.
const reownProjectId = String.fromEnvironment('REOWN_PROJECT_ID');

/// Outcome of a WalletConnect near:testnet pairing attempt.
class WalletConnectResult {
  /// [accountId] is set on success; [error] when pairing failed.
  const WalletConnectResult({this.accountId, this.error, this.uri});

  /// NEAR account from the WC session, if any.
  final String? accountId;

  /// Human-readable failure.
  final String? error;

  /// Pairing URI (for deep-linking into a wallet app).
  final String? uri;

  /// True when an account was returned.
  bool get ok => accountId != null && accountId!.isNotEmpty;
}

/// Opens an in-app WalletConnect SignClient (JS) for `near:testnet`.
///
/// Reown's Dart AppKit conflicts with `near_dart` / `share_plus` in this
/// tree, so pairing runs in a WebView against Reown Cloud [projectId].
/// The pairing URI is shown as a native QR once SignClient emits it.
Future<WalletConnectResult?> openWalletConnectFlow(
  BuildContext context, {
  String projectId = reownProjectId,
}) {
  return Navigator.of(context).push<WalletConnectResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => WalletConnectPage(projectId: projectId),
    ),
  );
}

/// Full-screen WC pairing page backed by [assets/wc/connect.html].
class WalletConnectPage extends StatefulWidget {
  /// [projectId] is the Reown Cloud project id.
  const WalletConnectPage({super.key, required this.projectId});

  /// Reown / WalletConnect Cloud project id.
  final String projectId;

  @override
  State<WalletConnectPage> createState() => _WalletConnectPageState();
}

class _WalletConnectPageState extends State<WalletConnectPage> {
  late final WebViewController _controller;
  String? _uri;
  String? _status;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(EngkwentroColors.navy)
      ..addJavaScriptChannel(
        'EngkwentroWc',
        onMessageReceived: _onMessage,
      );
    _loadHtml();
  }

  Future<void> _loadHtml() async {
    if (widget.projectId.isEmpty) {
      setState(() => _status = 'Set REOWN_PROJECT_ID to enable WalletConnect.');
      return;
    }
    final raw = await rootBundle.loadString('assets/wc/connect.html');
    // Bake project id into the page so the ES module can boot offline of query.
    final safeId =
        widget.projectId.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final withId = raw.replaceFirst(
      "params.get('projectId') || ''",
      "params.get('projectId') || '$safeId'",
    );
    await _controller.loadHtmlString(
      withId,
      baseUrl: 'https://engkwentro.local/',
    );
  }

  void _onMessage(JavaScriptMessage message) {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final type = data['type'] as String?;
      switch (type) {
        case 'uri':
          final uri = data['uri'] as String?;
          setState(() {
            _uri = uri;
            _status = 'Scan with your wallet, or Open wallet on this phone';
          });
        case 'connected':
          final accountId = data['accountId'] as String? ?? '';
          if (!mounted) return;
          Navigator.of(context).pop(
            WalletConnectResult(accountId: accountId, uri: _uri),
          );
        case 'error':
          setState(() => _status = data['message'] as String? ?? 'Error');
        case 'disconnected':
          setState(() => _status = 'Disconnected');
      }
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Future<void> _openUriExternally() async {
    final uri = _uri;
    if (uri == null || uri.isEmpty) return;
    final parsed = Uri.parse(uri);
    if (await canLaunchUrl(parsed)) {
      await launchUrl(parsed, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _copyUri() async {
    final uri = _uri;
    if (uri == null || uri.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: uri));
    if (!mounted) return;
    setState(() => _status = 'Connection link copied');
  }

  @override
  Widget build(BuildContext context) {
    final missing = widget.projectId.isEmpty;
    final uri = _uri;
    return Scaffold(
      backgroundColor: EngkwentroColors.navy,
      appBar: AppBar(
        title: const Text('WalletConnect'),
        actions: [
          if (uri != null)
            PixelTextButton(
              label: 'Open',
              onPressed: _openUriExternally,
            ),
        ],
      ),
      body: missing
          ? const _MissingProjectIdBody()
          : Stack(
              children: [
                // SignClient must keep running for approval(); keep the
                // WebView alive under the pairing overlay.
                WebViewWidget(controller: _controller),
                if (uri != null)
                  ColoredBox(
                    color: EngkwentroColors.navy,
                    child: SafeArea(
                      child: _PairingOverlay(
                        uri: uri,
                        status: _status,
                        onCopy: _copyUri,
                        onOpen: _openUriExternally,
                      ),
                    ),
                  )
                else if (_status != null)
                  Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        _status!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Large scannable QR for the WalletConnect pairing URI.
class _PairingOverlay extends StatelessWidget {
  const _PairingOverlay({
    required this.uri,
    required this.status,
    required this.onCopy,
    required this.onOpen,
  });

  final String uri;
  final String? status;
  final VoidCallback onCopy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Scan with your wallet',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Open a NEAR testnet wallet on another phone and scan this '
                'code. On this phone, use Open wallet instead.',
                textAlign: TextAlign.center,
                style: body,
              ),
              const SizedBox(height: 20),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: EngkwentroColors.cream,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: QrImageView(
                    data: uri,
                    version: QrVersions.auto,
                    size: 260,
                    gapless: true,
                    backgroundColor: EngkwentroColors.cream,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: EngkwentroColors.ink,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: EngkwentroColors.ink,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (status != null)
                Text(
                  status!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 16),
              PixelButton(
                label: 'Open wallet',
                onPressed: onOpen,
              ),
              const SizedBox(height: 8),
              PixelTextButton(
                label: 'Copy connection link',
                onPressed: onCopy,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Actionable empty state when [REOWN_PROJECT_ID] was not compiled in.
class _MissingProjectIdBody extends StatelessWidget {
  const _MissingProjectIdBody();

  static const _cloudUrl = 'https://cloud.reown.com';

  Future<void> _openCloud() async {
    final uri = Uri.parse(_cloudUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'WalletConnect needs a Reown Project ID',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Create play account works without this. For WalletConnect '
                'pairing only:',
                textAlign: TextAlign.center,
                style: body,
              ),
              const SizedBox(height: 16),
              Text('1. Open Reown Cloud and create a free project.', style: body),
              Text('2. Copy the Project ID.', style: body),
              Text(
                '3. Copy client/dart_defines.json.example → '
                'client/dart_defines.json and paste the id.',
                style: body,
              ),
              Text(
                '4. Full restart (not hot reload):\n'
                '   flutter run --dart-define-from-file=dart_defines.json',
                style: body,
              ),
              const SizedBox(height: 20),
              PixelButton(
                label: 'Open Reown Cloud',
                onPressed: _openCloud,
              ),
              const SizedBox(height: 8),
              Text(
                'Or use Create play account on the previous screen — no '
                'project id required.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

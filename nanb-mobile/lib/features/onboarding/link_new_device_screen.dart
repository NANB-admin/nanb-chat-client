import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/network/api_client.dart';
import 'widgets/onb_shell.dart';

/// Translated from `ScreenLinkNew` in the design source. Shown on the device
/// being linked: mints this device's OWN keypair (Ed25519 + X25519, not
/// phrase-derived), displays a QR for the primary to scan + authorize, then
/// polls the server and finishes the session once it's linked.
class LinkNewDeviceScreen extends ConsumerStatefulWidget {
  const LinkNewDeviceScreen({super.key});

  @override
  ConsumerState<LinkNewDeviceScreen> createState() => _LinkNewDeviceScreenState();
}

class _LinkNewDeviceScreenState extends ConsumerState<LinkNewDeviceScreen> {
  String? _payload;
  String? _fingerprint;
  String? _pubKeyHex;
  String _status = 'Waiting for primary device…';
  Timer? _poll;
  bool _completing = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_prepare);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _prepare() async {
    final prep = await ref.read(deviceLinkNotifierProvider).prepareNewDevice();
    if (!mounted) return;
    final hexUpper = prep.pubKeyHex.toUpperCase();
    final pairs = <String>[];
    for (var i = 0; i < hexUpper.length && i < 12; i += 4) {
      pairs.add(hexUpper.substring(i, i + 4));
    }
    setState(() {
      _payload = prep.qr;
      _fingerprint = pairs.join(' ');
      _pubKeyHex = prep.pubKeyHex;
    });
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _checkLinked());
  }

  Future<void> _checkLinked() async {
    final hex = _pubKeyHex;
    if (hex == null || _completing) return;
    final notifier = ref.read(deviceLinkNotifierProvider);
    final PendingDevice pending;
    try {
      pending = await notifier.pollPending(hex);
    } catch (_) {
      return; // transient — keep polling
    }
    if (!pending.linked || !mounted) return;
    _poll?.cancel();
    setState(() {
      _completing = true;
      _status = 'Authorized — finishing setup…';
    });
    try {
      await notifier.completeClaim(pending);
      if (!mounted) return;
      // This device now has its own session — drop the signed-out gates before
      // navigating (see ConversationsNotifier.clearSignedOutForNewSession).
      ref.read(conversationsProvider).clearSignedOutForNewSession();
      context.go(Routes.chatList);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _completing = false;
        _status = 'Setup failed: $e';
      });
      // Resume polling in case it was a transient finish failure.
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _checkLinked());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      body: OnbShell(
        subLabel: 'new device',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Link to your account',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              "On a device that's already signed in, open Settings → Linked devices → "
              'Link, and scan this code.',
              style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.5),
            ),
            const SizedBox(height: 24),
            _QrCard(t: t, payload: _payload, fingerprint: _fingerprint),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: t.accent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _status,
                  style: monoStyle(
                    fontSize: 10.5,
                    color: t.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _QrCard extends StatelessWidget {
  const _QrCard({required this.t, required this.payload, required this.fingerprint});
  final DesignTokens t;
  final String? payload;
  final String? fingerprint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.border),
      ),
      child: Column(
        children: [
          if (payload == null)
            SizedBox(
              width: 200,
              height: 200,
              child: Center(
                child: Text(
                  'No identity on this device.\nCreate or restore an account first.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.textMuted, fontSize: 12),
                ),
              ),
            )
          else
            QrImageView(
              data: payload!,
              version: QrVersions.auto,
              size: 200,
              // A QR must stay dark-on-light to scan. `t.text` is near-white in
              // dark mode, which washed the modules out into the white
              // background — pin the code to black-on-white in both themes.
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          const SizedBox(height: 14),
          Text(
            'DEVICE PUBKEY',
            style: monoStyle(
              fontSize: 10,
              color: t.textFaint,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            fingerprint ?? '— — —',
            style: monoStyle(fontSize: 12, color: t.text, letterSpacing: 0.5),
          ),
        ],
      ),
    );
  }
}

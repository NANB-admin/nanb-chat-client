import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/design_tokens.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/models/device_kind.dart';
import 'device_link_payload.dart';
import 'widgets/nanb_button.dart';
import 'widgets/onb_shell.dart';
import 'widgets/web_link_confirm_dialog.dart';

/// Translated from `ScreenLinkPrimary` in the design source. Wires the
/// device's camera via `mobile_scanner` to scan the QR shown on a new device's
/// `LinkNewDeviceScreen`. Once decoded, the user sees the new device's pubkey
/// fingerprint and can authorize it.
///
/// **Server side note:** the actual authorization endpoint (`POST /devices/link`
/// or equivalent) is deferred to a future plan that adds multi-device support.
/// Until then "Authorize" surfaces a snackbar so the UX flow is reviewable.
class LinkPrimaryDeviceScreen extends ConsumerStatefulWidget {
  const LinkPrimaryDeviceScreen({super.key});

  @override
  ConsumerState<LinkPrimaryDeviceScreen> createState() => _LinkPrimaryDeviceScreenState();
}

class _LinkPrimaryDeviceScreenState extends ConsumerState<LinkPrimaryDeviceScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  DeviceLinkPayload? _scanned;
  String? _formatError;
  bool _authorizing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned != null) return; // already locked onto a payload
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      try {
        final payload = DeviceLinkPayload.parse(raw);
        unawaited(_controller.stop());
        if (!mounted) return;
        setState(() {
          _scanned = payload;
          _formatError = null;
        });
        return;
      } on FormatException catch (e) {
        if (!mounted) return;
        setState(() => _formatError = e.message);
        // Keep scanning — a different barcode might still be the right one.
      }
    }
  }

  Future<void> _rescan() async {
    setState(() {
      _scanned = null;
      _formatError = null;
    });
    await _controller.start();
  }

  Future<void> _authorize() async {
    final payload = _scanned;
    if (payload == null || _authorizing) return;
    // A web QR could be shown by a lookalike site — make the user confirm.
    if (payload.kind == DeviceKind.web && !await confirmWebLink(context)) {
      return;
    }
    if (!mounted) return;
    setState(() => _authorizing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result =
          await ref.read(deviceLinkNotifierProvider).authorize(payload);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Device linked (${result.deviceId.substring(0, 8)}…). '
              'It will come online shortly.'),
        ),
      );
      // Return to the Linked devices list — the user authorized one device and
      // expects to land back where they started, not on a live scanner. (The
      // snackbar rides the parent ScaffoldMessenger, so it survives the pop.)
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _authorizing = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Could not authorize device: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      body: OnbShell(
        subLabel: 'primary device',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Authorize new device',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              'Point this camera at the QR code on your new device.',
              style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.5),
            ),
            const SizedBox(height: 20),
            _ScannerCard(
              t: t,
              controller: _controller,
              onDetect: _onDetect,
              scanned: _scanned,
            ),
            const SizedBox(height: 16),
            if (_scanned != null)
              _ConfirmCard(
                t: t,
                payload: _scanned!,
                onAuthorize: _authorize,
                onRescan: _rescan,
              )
            else
              _InfoCard(t: t, error: _formatError),
            const Spacer(),
            Text(
              '1 of 3 devices linked',
              textAlign: TextAlign.center,
              style: monoStyle(
                fontSize: 11,
                color: t.textFaint,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScannerCard extends StatelessWidget {
  const _ScannerCard({
    required this.t,
    required this.controller,
    required this.onDetect,
    required this.scanned,
  });

  final DesignTokens t;
  final MobileScannerController controller;
  final void Function(BarcodeCapture) onDetect;
  final DeviceLinkPayload? scanned;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Container(color: Colors.black),
            if (scanned == null)
              MobileScanner(controller: controller, onDetect: onDetect)
            else
              Center(
                child: Icon(Icons.check_circle, size: 64, color: t.accent),
              ),
            Positioned.fill(child: _ViewfinderOverlay(t: t, locked: scanned != null)),
          ],
        ),
      ),
    );
  }
}

class _ViewfinderOverlay extends StatelessWidget {
  const _ViewfinderOverlay({required this.t, required this.locked});
  final DesignTokens t;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final color = locked ? t.accent : t.accent;
    return IgnorePointer(
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.7,
          heightFactor: 0.7,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: color, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              Positioned(left: -2, top: -2, child: _corner(color, top: true, left: true)),
              Positioned(right: -2, top: -2, child: _corner(color, top: true, left: false)),
              Positioned(left: -2, bottom: -2, child: _corner(color, top: false, left: true)),
              Positioned(right: -2, bottom: -2, child: _corner(color, top: false, left: false)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _corner(Color color, {required bool top, required bool left}) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        border: Border(
          top: top ? BorderSide(color: color, width: 4) : BorderSide.none,
          bottom: !top ? BorderSide(color: color, width: 4) : BorderSide.none,
          left: left ? BorderSide(color: color, width: 4) : BorderSide.none,
          right: !left ? BorderSide(color: color, width: 4) : BorderSide.none,
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.t, required this.error});
  final DesignTokens t;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: t.warn.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.warn),
        ),
        child: Text(
          'Scanned a QR but it isn\'t a nanb device link: $error',
          style: monoStyle(fontSize: 11, color: t.warn).copyWith(height: 1.5),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: Text(
        'Up to 3 linked devices per account. Each device gets its own keys — '
        'compromise of one does not affect the others.',
        style: TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
      ),
    );
  }
}

class _ConfirmCard extends StatelessWidget {
  const _ConfirmCard({
    required this.t,
    required this.payload,
    required this.onAuthorize,
    required this.onRescan,
  });

  final DesignTokens t;
  final DeviceLinkPayload payload;
  final VoidCallback onAuthorize;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'NEW DEVICE',
            style: monoStyle(
              fontSize: 10,
              color: t.textFaint,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            payload.fingerprint,
            style: monoStyle(fontSize: 14, color: t.text, letterSpacing: 0.6),
          ),
          const SizedBox(height: 4),
          Text(
            payload.handleId,
            style: monoStyle(
              fontSize: 10,
              color: t.textMuted,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: NanbButton(
                  label: 'Rescan',
                  kind: NanbButtonKind.secondary,
                  onPressed: onRescan,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: NanbButton(
                  label: 'Authorize',
                  kind: NanbButtonKind.primary,
                  onPressed: onAuthorize,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


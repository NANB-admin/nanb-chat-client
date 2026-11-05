import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/design_tokens.dart';
import '../../app/theme.dart';
import 'contact_link_payload.dart';

/// Camera scanner for contact QRs (`nanb-link://contact?...` — the code on
/// a peer's settings identity card). On a successful parse it pops back to
/// [NewChatScreen] with the [ContactLinkPayload] as the route result; the
/// caller cross-checks the key against the server and starts the chat.
///
/// Same scanner skeleton as [LinkPrimaryDeviceScreen] (device linking) —
/// only the payload type and the exit path differ.
class ScanContactScreen extends StatefulWidget {
  const ScanContactScreen({super.key});

  @override
  State<ScanContactScreen> createState() => _ScanContactScreenState();
}

class _ScanContactScreenState extends State<ScanContactScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  bool _popped = false;
  String? _formatError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_popped) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      try {
        final payload = ContactLinkPayload.parse(raw);
        _popped = true;
        unawaited(_controller.stop());
        if (!mounted) return;
        context.pop(payload);
        return;
      } on FormatException catch (e) {
        if (!mounted) return;
        setState(() => _formatError = e.message);
        // Keep scanning — a different barcode might still be the right one.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back, color: t.text),
                    iconSize: 22,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'SCAN CONTACT QR',
                    style: monoStyle(
                      fontSize: 11,
                      color: t.textMuted,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                "Point the camera at the QR on your contact's settings "
                'screen (the icon next to their username).',
                style: TextStyle(fontSize: 13, color: t.textMuted, height: 1.5),
              ),
              const SizedBox(height: 20),
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: [
                      Container(color: Colors.black),
                      MobileScanner(
                        controller: _controller,
                        onDetect: _onDetect,
                      ),
                      Positioned.fill(child: _ViewfinderOverlay(t: t)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_formatError != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.warn.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: t.warn),
                  ),
                  child: Text(
                    "Scanned a QR but it isn't a nanb contact code: "
                    '$_formatError',
                    style: monoStyle(fontSize: 11, color: t.warn)
                        .copyWith(height: 1.5),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: t.border),
                  ),
                  child: Text(
                    'Scanning verifies their encryption key in the same '
                    'step — no typing, no impersonation.',
                    style:
                        TextStyle(fontSize: 12, color: t.textMuted, height: 1.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewfinderOverlay extends StatelessWidget {
  const _ViewfinderOverlay({required this.t});
  final DesignTokens t;

  @override
  Widget build(BuildContext context) {
    final color = t.accent;
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

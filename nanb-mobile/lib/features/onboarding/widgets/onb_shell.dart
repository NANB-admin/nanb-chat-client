import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';
import '../../../app/web_content_frame.dart';

/// Translated from the design's `OnbShell`. A header bar with the Chat wordmark
/// (mono, tracked) and an optional step counter on the right; content area
/// below with 24px padding.
class OnbShell extends StatelessWidget {
  const OnbShell({
    super.key,
    required this.child,
    this.brand = 'Chat',
    this.subLabel,
    this.hideBar = false,
  });

  final Widget child;
  final String brand;

  /// Right-aligned mono label, e.g. "01 / 04" or "restore".
  final String? subLabel;

  /// Welcome screen suppresses the header bar.
  final bool hideBar;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Container(
      color: t.bg,
      // Web only: onboarding is a narrow centred column, so its buttons don't
      // span a whole desktop window. No-op on mobile.
      child: WebContentFrame(
        maxWidth: 440,
        child: SafeArea(
        child: Column(
          children: [
            if (!hideBar)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t.border)),
                ),
                child: Row(
                  children: [
                    Text(
                      brand,
                      style: monoStyle(
                        fontSize: 11,
                        color: t.textMuted,
                        letterSpacing: 2,
                      ),
                    ),
                    const Spacer(),
                    if (subLabel != null)
                      Text(
                        subLabel!,
                        style: monoStyle(
                          fontSize: 10,
                          color: t.textFaint,
                          letterSpacing: 0.3,
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: Padding(padding: const EdgeInsets.all(24), child: child),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

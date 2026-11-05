import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';

/// "TODAY" / day separator line (translated from `DaySep`).
class DaySeparator extends StatelessWidget {
  const DaySeparator({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: t.border)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label.toUpperCase(),
              style: monoStyle(
                fontSize: 10,
                color: t.textFaint,
                letterSpacing: 1,
              ),
            ),
          ),
          Expanded(child: Container(height: 1, color: t.border)),
        ],
      ),
    );
  }
}

/// In-chat system line (translated from `SystemLine`). Pill-shaped.
class SystemLine extends StatelessWidget {
  const SystemLine({super.key, required this.text, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: t.surfaceAlt,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: t.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: t.textMuted),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                text,
                style: monoStyle(
                  fontSize: 10.5,
                  color: t.textMuted,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';

enum NanbButtonKind { primary, secondary, ghost, danger }

/// Translated from the design's `Btn` atom. Uppercase mono label + tracked
/// letter-spacing — utilitarian look. Border on every kind so they share
/// dimensions; the secondary variant is hollow.
class NanbButton extends StatelessWidget {
  const NanbButton({
    super.key,
    required this.label,
    this.onPressed,
    this.kind = NanbButtonKind.primary,
    this.fullWidth = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final NanbButtonKind kind;
  final bool fullWidth;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    late Color bg;
    late Color fg;
    late Color border;
    switch (kind) {
      case NanbButtonKind.primary:
        bg = t.accent;
        fg = t.accentOn;
        border = t.accent;
        break;
      case NanbButtonKind.secondary:
        bg = Colors.transparent;
        fg = t.text;
        border = t.borderStrong;
        break;
      case NanbButtonKind.ghost:
        bg = Colors.transparent;
        fg = t.textMuted;
        border = Colors.transparent;
        break;
      case NanbButtonKind.danger:
        bg = Colors.transparent;
        fg = t.danger;
        border = t.danger;
        break;
    }

    // Disabled (null onTap): mute every kind so it visibly reads as inactive
    // rather than a full-colour, tappable-looking button.
    final disabled = onPressed == null;
    if (disabled) {
      fg = t.textFaint;
      if (bg != Colors.transparent) bg = t.surfaceAlt;
      if (border != Colors.transparent) border = t.border;
    }

    final child = Row(
      mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 8),
        ],
        Text(
          label.toUpperCase(),
          style: monoStyle(
            fontSize: 13,
            color: fg,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );

    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        constraints: fullWidth ? const BoxConstraints(minWidth: double.infinity) : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border, width: 1),
        ),
        child: child,
      ),
    );
  }
}

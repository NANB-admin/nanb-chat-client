import 'package:flutter/material.dart';

/// Distinct, well-spaced hues for group sender names. Picked deterministically
/// from the sender's account id so a person keeps the same color in every
/// session and on every device.
const List<double> _hues = [
  350, 15, 35, 55, 85, 120, 150, 172, 190, 208, 228, 250, 272, 295, 318, 336,
];

/// A readable, stable name color for [senderKey] (an account id, or a device id
/// when the member is unknown). Lightness adapts to [brightness] so the name
/// keeps contrast on both the light and dark bubble backgrounds.
Color senderColorFor(String senderKey, Brightness brightness) {
  // FNV-1a: cheap and well-distributed for short ids.
  var h = 0x811c9dc5;
  for (final c in senderKey.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  final hue = _hues[h % _hues.length];
  final dark = brightness == Brightness.dark;
  return HSLColor.fromAHSL(1, hue, 0.65, dark ? 0.70 : 0.36).toColor();
}

/// The sender's name shown above their bubble in a group thread: large and bold
/// enough to follow a conversation at a glance, in the sender's own color.
class SenderNameLabel extends StatelessWidget {
  const SenderNameLabel({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 3),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

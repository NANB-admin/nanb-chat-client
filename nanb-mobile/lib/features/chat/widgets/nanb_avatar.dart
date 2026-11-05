import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// Translated from the design's `Avatar`. Circular avatar with initials,
/// deterministic OKLCH-style hue from the username.
class NanbAvatar extends StatelessWidget {
  const NanbAvatar({super.key, required this.name, this.size = 40});

  final String name;
  final double size;

  Color _hueFromName() {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) % 360;
    }
    return HSLColor.fromAHSL(1, h.toDouble(), 0.35, 0.5).toColor();
  }

  String _initials() {
    final cleaned = name.replaceFirst('@', '');
    if (cleaned.isEmpty) return '?';
    return cleaned.substring(0, cleaned.length >= 2 ? 2 : 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _hueFromName(),
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Text(
        _initials(),
        style: monoStyle(
          fontSize: size * 0.34,
          color: Colors.white,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

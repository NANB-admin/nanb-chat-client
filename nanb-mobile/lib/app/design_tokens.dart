import 'package:flutter/material.dart';

/// Design tokens for nanb. Translated 1:1 from
/// `docs/superpowers/design/extracted/cb9a85f5-*.tsx` (NanbTokens).
///
/// Palette is utilitarian / privacy-coded: warm neutrals + a single accent
/// (default Fern green). Two themes (light + dark) with parallel keys so the
/// same component code reads from a single `DesignTokens` instance.
@immutable
class DesignTokens {
  const DesignTokens({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.sunken,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.bubbleIn,
    required this.bubbleInBorder,
    required this.bubbleOut,
    required this.bubbleOutText,
    required this.danger,
    required this.warn,
    required this.accent,
    required this.accentOn,
  });

  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color sunken;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color textMuted;
  final Color textFaint;
  final Color bubbleIn;
  final Color bubbleInBorder;
  final Color bubbleOut;
  final Color bubbleOutText;
  final Color danger;
  final Color warn;
  final Color accent;
  final Color accentOn;

  static const DesignTokens light = DesignTokens(
    bg: Color(0xFFF5F5F2),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEFEFEA),
    sunken: Color(0xFFE8E8E2),
    border: Color(0xFFE1E1DA),
    borderStrong: Color(0xFFCFCFC6),
    text: Color(0xFF171818),
    textMuted: Color(0xFF5C5E5C),
    textFaint: Color(0xFF8B8E8A),
    bubbleIn: Color(0xFFFFFFFF),
    bubbleInBorder: Color(0xFFE1E1DA),
    bubbleOut: Color(0xFF171818),
    bubbleOutText: Color(0xFFF5F5F2),
    danger: Color(0xFFB0322B),
    warn: Color(0xFFA36B12),
    accent: Color(0xFF5FAE7A), // Fern (default)
    accentOn: Color(0xFF0B1A12),
  );

  static const DesignTokens dark = DesignTokens(
    bg: Color(0xFF0E0F10),
    surface: Color(0xFF17191A),
    surfaceAlt: Color(0xFF1D1F20),
    sunken: Color(0xFF0A0B0C),
    border: Color(0xFF26282A),
    borderStrong: Color(0xFF33363A),
    text: Color(0xFFE8E8E2),
    textMuted: Color(0xFF9A9D98),
    textFaint: Color(0xFF6B6E69),
    bubbleIn: Color(0xFF1D1F20),
    bubbleInBorder: Color(0xFF26282A),
    bubbleOut: Color(0xFFE8E8E2),
    bubbleOutText: Color(0xFF0E0F10),
    danger: Color(0xFFE26B62),
    warn: Color(0xFFD4A04E),
    accent: Color(0xFF5FAE7A),
    accentOn: Color(0xFF0B1A12),
  );

  /// Convenience: pick the right tokens for a [Brightness].
  static DesignTokens of(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? dark : light;
  }
}

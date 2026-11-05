import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// Brand tokens kept here for backward-compat with earlier code.
class BrandTokens {
  BrandTokens._();
  static const Color cream = Color(0xFFFAF9F5);
  static const Color nearBlack = Color(0xFF0E0F10);
  static const Color sageGreen = Color(0xFF5FAE7A);
  static const String monoFontFamily = 'IBMPlexMono';
}

/// `IBM Plex Mono` style for monospace usage (badges, timestamps, fingerprints).
///
/// Uses the font BUNDLED in assets/fonts (see pubspec `fonts:`), never
/// `google_fonts` — that package fetched the font from Google's CDN on first
/// launch with the device's real IP, outside Tor. Bundling keeps fonts fully
/// on-device.
TextStyle monoStyle({
  required double fontSize,
  Color? color,
  double? letterSpacing,
  FontWeight? fontWeight,
}) {
  return TextStyle(
    fontFamily: BrandTokens.monoFontFamily,
    fontSize: fontSize,
    color: color,
    letterSpacing: letterSpacing,
    fontWeight: fontWeight,
  );
}

ThemeData _buildTheme(DesignTokens t, Brightness brightness) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.accent,
      brightness: brightness,
      surface: t.surface,
      primary: t.accent,
      onPrimary: t.accentOn,
      error: t.danger,
    ),
    scaffoldBackgroundColor: t.bg,
  );
  return base.copyWith(
    // Inter, BUNDLED locally (assets/fonts/Inter-Variable.ttf). Was
    // GoogleFonts.interTextTheme(...), which fetched Inter from Google's CDN on
    // first launch with the real IP (outside Tor) — now nothing leaves the
    // device for fonts.
    textTheme: base.textTheme.apply(
      fontFamily: 'Inter',
      bodyColor: t.text,
      displayColor: t.text,
    ),
  );
}

ThemeData buildLightTheme() => _buildTheme(DesignTokens.light, Brightness.light);
ThemeData buildDarkTheme() => _buildTheme(DesignTokens.dark, Brightness.dark);

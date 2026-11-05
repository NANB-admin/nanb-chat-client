import 'package:flutter/painting.dart';

import 'chat_pattern.dart';

/// The backdrop behind the messages in every chat thread.
///
/// [nanb] (the default) is the theme background with a tumbled "NANb" wordmark
/// pattern; [none] is the plain flat theme background. The named presets are soft
/// gradients with a light and a dark variant, so they follow the app theme, and
/// some also carry a [pattern].
/// [custom] is a photo the user picked; its file path is stored separately in
/// `AppPreferences.chatBackgroundPath`.
enum ChatBackground {
  nanb('NANb'),
  doodles('Doodles'),
  confetti('Confetti'),
  waves('Waves'),
  stars('Stars'),
  none('Plain'),
  fern('Fern'),
  ocean('Ocean'),
  dusk('Dusk'),
  sunset('Sunset'),
  graphite('Graphite'),
  custom('Photo');

  const ChatBackground(this.label);

  final String label;

  /// The repeating design drawn over the backdrop, or null for none.
  ChatPattern? get pattern {
    switch (this) {
      case ChatBackground.nanb:
        return ChatPattern.nanb;
      case ChatBackground.doodles:
        return ChatPattern.doodles;
      case ChatBackground.confetti:
        return ChatPattern.confetti;
      case ChatBackground.waves:
        return ChatPattern.waves;
      case ChatBackground.stars:
        return ChatPattern.stars;
      default:
        return null;
    }
  }

  /// The preset's gradient colours (top → bottom), or null when the plain theme
  /// background shows through ([none], [nanb], [doodles], [custom]).
  List<Color>? colors({required bool dark}) {
    switch (this) {
      case ChatBackground.none:
      case ChatBackground.nanb:
      case ChatBackground.doodles:
      case ChatBackground.custom:
        return null;
      case ChatBackground.confetti:
        return dark
            ? const [Color(0xFF2A1A2E), Color(0xFF3F2347)]
            : const [Color(0xFFFCE4EC), Color(0xFFF8BBD0)];
      case ChatBackground.waves:
        return dark
            ? const [Color(0xFF0A1F2E), Color(0xFF0F3A52)]
            : const [Color(0xFFD9F1F7), Color(0xFFA9DCEB)];
      case ChatBackground.stars:
        return dark
            ? const [Color(0xFF0B0E24), Color(0xFF1B1F4A)]
            : const [Color(0xFF2B2F6B), Color(0xFF4A4F9C)];
      case ChatBackground.fern:
        return dark
            ? const [Color(0xFF0F1F17), Color(0xFF16301F)]
            : const [Color(0xFFE3F2E8), Color(0xFFC6E4D0)];
      case ChatBackground.ocean:
        return dark
            ? const [Color(0xFF0B1A26), Color(0xFF123249)]
            : const [Color(0xFFE0EFFA), Color(0xFFBBDCF2)];
      case ChatBackground.dusk:
        return dark
            ? const [Color(0xFF1A1428), Color(0xFF2E2147)]
            : const [Color(0xFFECE4F7), Color(0xFFD3C4EC)];
      case ChatBackground.sunset:
        return dark
            ? const [Color(0xFF2A1612), Color(0xFF47241A)]
            : const [Color(0xFFFBE9DC), Color(0xFFF5C9AE)];
      case ChatBackground.graphite:
        return dark
            ? const [Color(0xFF121314), Color(0xFF1E2022)]
            : const [Color(0xFFE9E9E6), Color(0xFFD5D5D0)];
    }
  }

  static ChatBackground fromName(String? name) {
    return ChatBackground.values.firstWhere(
      (b) => b.name == name,
      orElse: () => ChatBackground.nanb,
    );
  }
}

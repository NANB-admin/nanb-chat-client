import 'dart:io';

import 'package:flutter/material.dart';

import '../../settings/models/chat_background.dart';
import '../../settings/models/chat_pattern.dart';
import 'chat_pattern_painter.dart';

/// Paints the user's chosen chat backdrop behind [child]. With no backdrop (or a
/// photo that can't be read) it paints nothing, leaving the theme background.
class ChatBackgroundView extends StatelessWidget {
  const ChatBackgroundView({
    super.key,
    required this.background,
    required this.customPath,
    required this.child,
  });

  final ChatBackground background;
  final String customPath;
  final Widget child;

  /// Mark colour per pattern. The wordmark and doodles sit on the plain theme
  /// background so they use a faint theme-aware ink; the others sit on their own
  /// gradient and read as lighter highlights on it.
  static Color _ink(ChatPattern pattern, bool dark) {
    switch (pattern) {
      case ChatPattern.nanb:
      case ChatPattern.doodles:
        return (dark ? Colors.white : Colors.black).withValues(alpha: .07);
      case ChatPattern.confetti:
      case ChatPattern.waves:
        return Colors.white.withValues(alpha: dark ? .10 : .55);
      case ChatPattern.stars:
        return Colors.white.withValues(alpha: dark ? .40 : .55);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = background.colors(dark: dark);
    Widget? backdrop;
    if (colors != null) {
      backdrop = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors,
          ),
        ),
      );
    } else if (background == ChatBackground.custom && customPath.isNotEmpty) {
      backdrop = Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(customPath),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          // Dim the photo so bubbles stay readable on a busy picture.
          ColoredBox(color: Colors.black.withValues(alpha: dark ? 0.35 : 0.1)),
        ],
      );
    }
    final pattern = background.pattern;
    if (pattern != null) {
      // Patterns sit above the gradient (or the bare theme background) and
      // below the messages. RepaintBoundary: the design is static, so message
      // scrolling and new bubbles must not re-rasterise it.
      final overlay = RepaintBoundary(
        child: CustomPaint(
          painter: ChatPatternPainter(pattern: pattern, ink: _ink(pattern, dark)),
          size: Size.infinite,
        ),
      );
      backdrop = backdrop == null
          ? overlay
          : Stack(fit: StackFit.expand, children: [backdrop, overlay]);
    }
    if (backdrop == null) return child;
    return Stack(
      fit: StackFit.expand,
      children: [Positioned.fill(child: backdrop), child],
    );
  }
}

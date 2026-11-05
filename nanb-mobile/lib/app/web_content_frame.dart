import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Keeps content in a centred column of at most [maxWidth] on the WEB build, so
/// a phone-shaped UI doesn't stretch across a desktop browser window (full-width
/// buttons, edge-to-edge text). On mobile it returns [child] untouched — the
/// mobile layout is deliberately left exactly as it was.
///
/// [enabled] defaults to "running in a browser"; tests pass it explicitly.
class WebContentFrame extends StatelessWidget {
  const WebContentFrame({
    super.key,
    required this.child,
    this.maxWidth = 640,
    bool? enabled,
  }) : _enabled = enabled;

  final Widget child;

  /// Widest the content may grow, in logical pixels.
  final double maxWidth;

  final bool? _enabled;

  bool get enabled => _enabled ?? kIsWeb;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}

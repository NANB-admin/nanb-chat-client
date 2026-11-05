import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';

/// Neutral, branded loading state for a conversation that hasn't resolved yet —
/// shown by the chat thread while it (re)connects and catches up, instead of a
/// bare spinner. Carries the app mark, a [message] describing what's happening,
/// and an optional [detail] line, with the spinner underneath.
///
/// Presentational only: the caller computes [message]/[detail] from the live
/// connection + transport state.
class ConversationLoadingView extends StatelessWidget {
  const ConversationLoadingView({
    super.key,
    required this.message,
    this.detail,
  });

  /// The headline, e.g. "Reconnecting over Tor…".
  final String message;

  /// Optional secondary line, e.g. why it might take a moment.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The Chat app mark. errorBuilder keeps the screen intact if the
          // asset ever fails to decode — a generic glyph stands in.
          Image.asset(
            'assets/icon/app_icon_foreground.png',
            width: 88,
            height: 88,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) =>
                Icon(Icons.lock_outline, size: 64, color: t.accent),
          ),
          const SizedBox(height: 20),
          Text(
            message,
            textAlign: TextAlign.center,
            style: monoStyle(fontSize: 14, color: t.text, letterSpacing: 0.5),
          ),
          if (detail != null) ...[
            const SizedBox(height: 8),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textMuted, fontSize: 12, height: 1.4),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
          ),
        ],
      ),
    );
  }
}

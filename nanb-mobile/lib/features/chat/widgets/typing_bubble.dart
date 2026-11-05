import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';

/// The three bouncing dots shown at the bottom of a thread while the peer is
/// composing, in an incoming-style bubble (the WhatsApp "..." indicator).
class TypingBubble extends StatefulWidget {
  const TypingBubble({super.key});

  @override
  State<TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DesignTokens.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: t.bubbleIn,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: t.bubbleInBorder),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                _Dot(color: t.textMuted, lift: _lift(i)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 0..1 bounce for dot [i]; each dot trails the previous by a fifth of a cycle.
  double _lift(int i) {
    final phase = (_controller.value - i * 0.2) % 1.0;
    return phase < 0.4 ? math.sin(phase / 0.4 * math.pi) : 0;
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.lift});

  final Color color;
  final double lift;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(0, -4 * lift),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.45 + 0.4 * lift),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

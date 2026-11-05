import 'package:flutter/material.dart';

import '../../../app/design_tokens.dart';
import '../../../app/theme.dart';
import '../voice/voice_player_controller.dart';

/// Voice-note bubble. When `controller` is supplied, the play icon, waveform
/// progress, and duration label rebind to the controller's state on each
/// `notifyListeners`. Tapping the play icon invokes [onPlayPause].
///
/// `controller`-less rendering uses the static `duration` + `progress` props
/// — useful for preview / design-mode rendering.
class MessageBubbleVoice extends StatelessWidget {
  const MessageBubbleVoice({
    super.key,
    required this.time,
    required this.mine,
    this.controller,
    this.duration = '0:00',
    this.progress = 0.0,
    this.onPlayPause,
    this.onSeek,
    this.waveformSamples,
  });

  final String time;
  final bool mine;
  final VoicePlayerController? controller;

  /// Duration label used when `controller` is null (not yet loaded) —
  /// callers pass the descriptor's recorded duration so the real length
  /// shows before the audio is ever downloaded.
  final String duration;

  /// Fallback used when `controller` is null. 0..1.
  final double progress;

  final VoidCallback? onPlayPause;

  /// Called with the tapped/dragged fraction (0..1) of the waveform —
  /// WhatsApp-style scrubbing. Null disables seeking (e.g. not loaded yet).
  final ValueChanged<double>? onSeek;

  /// Per-recording amplitude bars (each 0..255). Null falls back to the
  /// static decorative waveform — used when the message predates the
  /// waveform feature or the sender's recording was too short to capture
  /// amplitudes.
  final List<int>? waveformSamples;

  @override
  Widget build(BuildContext context) {
    if (controller == null) return _build(context, progress, duration, false);
    return AnimatedBuilder(
      animation: controller!,
      builder: (ctx, _) => _build(
        ctx,
        controller!.progress,
        controller!.durationLabel,
        controller!.isPlaying,
      ),
    );
  }

  Widget _build(BuildContext context, double prog, String durLabel, bool playing) {
    final t = DesignTokens.of(context);
    final bg = mine ? t.bubbleOut : t.bubbleIn;
    final fg = mine ? t.bubbleOutText : t.text;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: mine ? Colors.transparent : t.bubbleInBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: onPlayPause,
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: t.accent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      playing ? Icons.pause : Icons.play_arrow,
                      color: t.accentOn,
                      size: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 24,
                    child: LayoutBuilder(
                      builder: (ctx, constraints) {
                        final w = constraints.maxWidth;
                        void seekAt(double dx) {
                          if (onSeek == null || w <= 0) return;
                          onSeek!((dx / w).clamp(0.0, 1.0));
                        }

                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => seekAt(d.localPosition.dx),
                          onHorizontalDragStart: (d) =>
                              seekAt(d.localPosition.dx),
                          onHorizontalDragUpdate: (d) =>
                              seekAt(d.localPosition.dx),
                          child: CustomPaint(
                            size: Size(w, 24),
                            painter: _WaveformPainter(
                              played: t.accent,
                              unplayed: fg.withValues(alpha: 0.35),
                              progress: prog.clamp(0.0, 1.0),
                              samples: waveformSamples,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  durLabel,
                  style: monoStyle(
                    fontSize: 11,
                    color: fg,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              time,
              style: monoStyle(
                fontSize: 9.5,
                color: fg.withValues(alpha: 0.7),
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.played,
    required this.unplayed,
    required this.progress,
    this.samples,
  });

  final Color played;
  final Color unplayed;
  final double progress;

  /// Per-recording amplitudes (0..255). When null or empty, [_fallbackHeights]
  /// renders a decorative waveform that matches the original design.
  final List<int>? samples;

  static const _fallbackHeights = <double>[
    0.30, 0.55, 0.40, 0.75, 0.62, 0.88, 0.50, 0.95, 0.60, 0.78,
    0.42, 0.85, 0.55, 0.90, 0.70, 0.45, 0.82, 0.58, 0.92, 0.40,
    0.65, 0.78, 0.48, 0.85, 0.58, 0.72, 0.40, 0.55,
  ];

  /// Resolved bar heights (0..1) — either normalized sample bytes or the
  /// fallback decorative pattern.
  List<double> get _heights {
    final s = samples;
    if (s == null || s.isEmpty) return _fallbackHeights;
    // Captured silence reads as ~0 — clamp the minimum so every bar is at
    // least visible, otherwise quiet recordings look like an empty bubble.
    const minBar = 0.12;
    return s
        .map((b) => (b / 255.0).clamp(0.0, 1.0))
        .map((v) => v < minBar ? minBar : v)
        .toList(growable: false);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final heights = _heights;
    final barCount = heights.length;
    if (barCount == 0) return;
    final barWidth = size.width / (barCount * 1.6);
    final spacing = barCount > 1
        ? (size.width - barWidth * barCount) / (barCount - 1)
        : 0.0;
    final centerY = size.height / 2;
    final progressBarIndex = (progress * barCount).floor();

    for (var i = 0; i < barCount; i++) {
      final h = heights[i] * size.height;
      final x = i * (barWidth + spacing);
      final paint = Paint()
        ..color = i < progressBarIndex ? played : unplayed
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x + barWidth / 2, centerY - h / 2),
        Offset(x + barWidth / 2, centerY + h / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.played != played ||
      oldDelegate.unplayed != unplayed ||
      oldDelegate.progress != progress ||
      !_listEq(oldDelegate.samples, samples);

  static bool _listEq(List<int>? a, List<int>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

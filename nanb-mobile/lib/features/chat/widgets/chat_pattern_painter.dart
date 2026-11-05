import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../settings/models/chat_pattern.dart';

/// Paints a [ChatPattern] as small, low-contrast marks in [ink].
///
/// Layout is deterministic (each cell's jitter comes from a hash of its grid
/// position), so the pattern never shimmers between repaints and looks the same
/// on every device.
class ChatPatternPainter extends CustomPainter {
  const ChatPatternPainter({required this.pattern, required this.ink});

  final ChatPattern pattern;
  final Color ink;

  static const _doodleIcons = <IconData>[
    Icons.chat_bubble_outline,
    Icons.lock_outline,
    Icons.favorite_border,
    Icons.star_border,
    Icons.bolt_outlined,
    Icons.mic_none,
    Icons.emoji_emotions_outlined,
    Icons.photo_camera_outlined,
  ];

  /// Stable pseudo-random value in [0, 1) for a cell and a salt.
  static double _rand(int x, int y, int salt) {
    var h = (x * 374761393 + y * 668265263 + salt * 2147483647) & 0x7FFFFFFF;
    h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF;
    h = h ^ (h >> 16);
    return (h & 0xFFFF) / 0x10000;
  }

  @override
  void paint(Canvas canvas, Size size) {
    switch (pattern) {
      case ChatPattern.nanb:
        _paintNanb(canvas, size);
      case ChatPattern.doodles:
        _paintDoodles(canvas, size);
      case ChatPattern.confetti:
        _paintConfetti(canvas, size);
      case ChatPattern.waves:
        _paintWaves(canvas, size);
      case ChatPattern.stars:
        _paintStars(canvas, size);
    }
  }

  void _drawRotated(Canvas canvas, TextPainter tp, Offset center, double angle) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  void _paintNanb(Canvas canvas, Size size) {
    const cellW = 96.0, cellH = 58.0;
    final rows = (size.height / cellH).ceil() + 1;
    final cols = (size.width / cellW).ceil() + 1;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        // Brick-stagger every other row, then jitter + tumble each mark.
        final dx = (r.isOdd ? cellW / 2 : 0) + (_rand(c, r, 1) - .5) * 18;
        final dy = (_rand(c, r, 2) - .5) * 14;
        final tp = TextPainter(
          text: TextSpan(
            text: 'NANb',
            style: TextStyle(
              color: ink.withValues(alpha: ink.a * (.55 + _rand(c, r, 3) * .45)),
              fontSize: 10 + _rand(c, r, 4) * 6,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final angle = (_rand(c, r, 5) - .5) * 1.0 - .2;
        _drawRotated(canvas, tp,
            Offset(c * cellW + dx + cellW / 2, r * cellH + dy + cellH / 2), angle);
      }
    }
  }

  void _paintDoodles(Canvas canvas, Size size) {
    const cell = 64.0;
    final rows = (size.height / cell).ceil() + 1;
    final cols = (size.width / cell).ceil() + 1;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final icon = _doodleIcons[(_rand(c, r, 6) * _doodleIcons.length).floor()];
        final tp = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(
              fontFamily: icon.fontFamily,
              package: icon.fontPackage,
              fontSize: 17 + _rand(c, r, 7) * 7,
              color: ink,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final dx = (r.isOdd ? cell / 2 : 0) + (_rand(c, r, 8) - .5) * 14;
        final dy = (_rand(c, r, 9) - .5) * 14;
        _drawRotated(canvas, tp,
            Offset(c * cell + dx + cell / 2, r * cell + dy + cell / 2),
            (_rand(c, r, 10) - .5) * .9);
      }
    }
  }

  void _paintConfetti(Canvas canvas, Size size) {
    const cell = 34.0;
    final paint = Paint();
    for (var r = 0; r < (size.height / cell).ceil() + 1; r++) {
      for (var c = 0; c < (size.width / cell).ceil() + 1; c++) {
        paint.color =
            ink.withValues(alpha: ink.a * (.5 + _rand(c, r, 11) * .5));
        canvas.drawCircle(
          Offset(c * cell + _rand(c, r, 12) * cell,
              r * cell + _rand(c, r, 13) * cell),
          1.5 + _rand(c, r, 14) * 4.5,
          paint,
        );
      }
    }
  }

  void _paintWaves(Canvas canvas, Size size) {
    const gap = 30.0;
    final paint = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (var r = 0; r < (size.height / gap).ceil() + 1; r++) {
      final path = Path();
      final phase = r * 1.3;
      for (double x = 0; x <= size.width + 4; x += 4) {
        final y = r * gap + math.sin(x / 26 + phase) * 6;
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(path, paint);
    }
  }

  void _paintStars(Canvas canvas, Size size) {
    const cell = 46.0;
    final paint = Paint();
    for (var r = 0; r < (size.height / cell).ceil() + 1; r++) {
      for (var c = 0; c < (size.width / cell).ceil() + 1; c++) {
        final center = Offset(c * cell + _rand(c, r, 15) * cell,
            r * cell + _rand(c, r, 16) * cell);
        paint.color = ink.withValues(alpha: ink.a * (.4 + _rand(c, r, 17) * .6));
        if (_rand(c, r, 18) < .45) {
          _fourPointStar(canvas, center, 3 + _rand(c, r, 19) * 5, paint);
        } else {
          canvas.drawCircle(center, .8 + _rand(c, r, 20) * 1.2, paint);
        }
      }
    }
  }

  void _fourPointStar(Canvas canvas, Offset c, double r, Paint paint) {
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx, c.dy, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx, c.dy, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(ChatPatternPainter old) =>
      old.pattern != pattern || old.ink != ink;
}

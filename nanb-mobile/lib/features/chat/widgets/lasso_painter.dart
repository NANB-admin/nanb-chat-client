import 'package:flutter/material.dart';

/// Draws the freehand outline the user is tracing over the sticker image: a
/// light tint inside the shape and a two-tone stroke (dark under bright) so it
/// stays visible on both light and dark photos. The path is closed visually, the
/// same way the cut will close it.
class LassoPainter extends CustomPainter {
  const LassoPainter({required this.points, required this.color});

  final List<Offset> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..addPolygon(points, true);
    canvas.drawPath(
      path,
      Paint()..color = color.withValues(alpha: 0.18),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black54,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(LassoPainter old) =>
      old.points != points || old.color != color;
}

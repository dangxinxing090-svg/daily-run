import 'dart:math' as math;

import 'package:flutter/material.dart';

enum DailyGlyph {
  calendar,
  route,
  list,
  edit,
  pause,
  finish,
  clock,
  pace,
  check,
  share,
  download,
  restore,
  trash,
  energy,
  back,
}

/// 湖蓝留白原型的线性图标。24 网格、1.5 描边、圆端圆角。
class DailyIcon extends StatelessWidget {
  final DailyGlyph glyph;
  final double size;
  final Color? color;

  const DailyIcon(this.glyph, {super.key, this.size = 20, this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _DailyIconPainter(
          glyph,
          color ??
              IconTheme.of(context).color ??
              DefaultTextStyle.of(context).style.color ??
              const Color(0xFF1F211F),
        ),
      );
}

class _DailyIconPainter extends CustomPainter {
  final DailyGlyph glyph;
  final Color color;

  _DailyIconPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.scale(size.width / 24, size.height / 24);
    final p = Path();
    void line(double x, double y, double endX, double endY) =>
        canvas.drawLine(Offset(x, y), Offset(endX, endY), paint);
    void dot(double x, double y, double r) =>
        canvas.drawCircle(Offset(x, y), r, paint);
    void box(
            double x, double y, double w, double h, double r) =>
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(x, y, w, h), Radius.circular(r)),
            paint);

    switch (glyph) {
      case DailyGlyph.back:
        line(14, 6, 8, 12);
        line(8, 12, 14, 18);
      case DailyGlyph.calendar:
        box(3.5, 5, 17, 15.5, 2.5);
        line(3.5, 10, 20.5, 10);
        line(8, 3, 8, 6.5);
        line(16, 3, 16, 6.5);
      case DailyGlyph.route:
        dot(5.5, 18.5, 2.2);
        dot(18.5, 6.5, 1.2);
        p.moveTo(18.5, 2.5);
        p.arcToPoint(const Offset(22.5, 6.5), radius: const Radius.circular(4));
        p.cubicTo(22.5, 10, 18.5, 14.5, 18.5, 14.5);
        p.cubicTo(18.5, 14.5, 14.5, 10, 14.5, 6.5);
        p.arcToPoint(const Offset(18.5, 2.5), radius: const Radius.circular(4));
        p.moveTo(7.3, 17.3);
        p.cubicTo(9, 13, 12, 15, 15, 12.5);
      case DailyGlyph.list:
        for (final y in [6.5, 12.0, 17.5]) {
          line(3.5, y, 5.5, y);
          line(8.5, y, 20, y);
        }
      case DailyGlyph.edit:
        p.moveTo(4.6, 16.8);
        p.lineTo(16.35, 5);
        p.quadraticBezierTo(17.8, 3.55, 19.65, 5.4);
        p.quadraticBezierTo(21.1, 6.85, 19.65, 8.3);
        p.lineTo(7.85, 20.1);
        p.lineTo(3.55, 21.15);
        p.close();
        line(14.85, 6.5, 18.15, 9.8);
      case DailyGlyph.pause:
        line(9, 5, 9, 19);
        line(15, 5, 15, 19);
      case DailyGlyph.finish:
        line(6, 21, 6, 3);
        p.moveTo(6, 4);
        p.lineTo(18, 4);
        p.lineTo(15.5, 8);
        p.lineTo(18, 12);
        p.lineTo(6, 12);
      case DailyGlyph.clock:
        dot(12, 12, 8.5);
        p.moveTo(12, 7);
        p.lineTo(12, 12);
        p.lineTo(15.5, 14);
      case DailyGlyph.pace:
        p.arcTo(Rect.fromCircle(center: const Offset(12, 13.5), radius: 8.5),
            math.pi * .86, math.pi * 1.28, true);
        line(12, 17, 15.5, 10.5);
        dot(12, 17, 1.2);
      case DailyGlyph.check:
        dot(12, 12, 8.5);
        p.moveTo(8, 12.2);
        p.lineTo(11, 15);
        p.lineTo(16, 9);
      case DailyGlyph.share:
      case DailyGlyph.download:
        p.moveTo(6, 11);
        p.lineTo(5, 11);
        p.quadraticBezierTo(3.5, 11, 3.5, 12.5);
        p.lineTo(3.5, 19);
        p.quadraticBezierTo(3.5, 20.5, 5, 20.5);
        p.lineTo(19, 20.5);
        p.quadraticBezierTo(20.5, 20.5, 20.5, 19);
        p.lineTo(20.5, 12.5);
        p.quadraticBezierTo(20.5, 11, 19, 11);
        p.lineTo(18, 11);
        final down = glyph == DailyGlyph.download;
        final tip = down ? 15.0 : 3.0;
        final flank = down ? 11.5 : 6.5;
        line(12, 3, 12, 15);
        p.moveTo(8.5, flank);
        p.lineTo(12, tip);
        p.lineTo(15.5, flank);
      case DailyGlyph.restore:
        p.arcTo(Rect.fromCircle(center: const Offset(12, 12), radius: 8),
            math.pi, math.pi * 1.78, true);
        p.moveTo(3.5, 7);
        p.lineTo(4, 12);
        p.lineTo(9, 11);
      case DailyGlyph.trash:
        line(4.5, 6, 19.5, 6);
        p.moveTo(9, 6);
        p.lineTo(9, 3.5);
        p.lineTo(15, 3.5);
        p.lineTo(15, 6);
        p.moveTo(6.5, 6);
        p.lineTo(7.4, 20);
        p.lineTo(16.6, 20);
        p.lineTo(17.5, 6);
        line(10, 10, 10, 16);
        line(14, 10, 14, 16);
      case DailyGlyph.energy:
        p.moveTo(13, 3);
        p.lineTo(6, 13);
        p.lineTo(11.4, 13);
        p.lineTo(10.8, 21);
        p.lineTo(18, 10.8);
        p.lineTo(12.6, 10.8);
        p.close();
    }
    canvas.drawPath(p, paint);
  }

  @override
  bool shouldRepaint(covariant _DailyIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}

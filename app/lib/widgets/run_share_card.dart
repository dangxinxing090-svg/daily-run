import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../theme.dart';
import 'track_path.dart';

Color _c(int v) => Color(v);

String _clockText(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

String _paceText(double secPerKm) {
  if (secPerKm <= 0) return '--\'--"';
  final s = secPerKm.round();
  return '${s ~/ 60}\'${(s % 60).toString().padLeft(2, '0')}"';
}

/// 3:4 运动记录卡。屏上预览与导出 PNG 共用这一个 widget，
/// 保证导出的图片与用户看到的一致。
class RunShareCard extends StatelessWidget {
  final WorkoutSession session;
  final String dateLabel;

  const RunShareCard({
    super.key,
    required this.session,
    required this.dateLabel,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 750,
      height: 1000,
      child: CustomPaint(
        painter: _CardPainter(session: session, dateLabel: dateLabel),
        size: const Size(750, 1000),
      ),
    );
  }
}

class _CardPainter extends CustomPainter {
  final WorkoutSession session;
  final String dateLabel;

  _CardPainter({required this.session, required this.dateLabel});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _c(AppPalette.sand1));

    // 顶部斜切橙带
    final band = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, 250)
      ..lineTo(0, 330)
      ..close();
    canvas.drawPath(band, Paint()..color = _c(AppPalette.accentStrong));

    // 轨迹区
    final mapTop = 380.0;
    final mapRect = Rect.fromLTWH(48, mapTop, size.width - 96, 330);
    canvas.drawRRect(
      RRect.fromRectAndRadius(mapRect, const Radius.circular(18)),
      Paint()..color = _c(AppPalette.sand2),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(mapRect, const Radius.circular(18)),
      Paint()
        ..color = _c(AppPalette.slate6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    // 网格
    final grid = Paint()
      ..color = _c(AppPalette.slate6)
      ..strokeWidth = 0.5;
    for (int i = 1; i < 5; i++) {
      final y = mapRect.top + mapRect.height * i / 5;
      canvas.drawLine(Offset(mapRect.left, y), Offset(mapRect.right, y), grid);
    }
    for (int i = 1; i < 4; i++) {
      final x = mapRect.left + mapRect.width * i / 4;
      canvas.drawLine(Offset(x, mapRect.top), Offset(x, mapRect.bottom), grid);
    }

    if (session.points.length >= 2) {
      canvas.save();
      canvas.translate(mapRect.left, mapRect.top);
      final proj = projectTrack(session.points, mapRect.size, pad: 34);
      final path = Path()..moveTo(proj.points.first.dx, proj.points.first.dy);
      for (final p in proj.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _c(AppPalette.accentStrong)
          ..strokeWidth = 9
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      if (proj.end != null) {
        canvas.drawCircle(proj.end!, 12, Paint()..color = _c(AppPalette.accentStrong));
        canvas.drawCircle(proj.end!, 6, Paint()..color = _c(AppPalette.slate1));
      }
      canvas.restore();
    } else {
      _text(canvas, '本次无有效轨迹', Offset(mapRect.left + 24, mapRect.top + 40),
          22, _c(AppPalette.slate11));
    }

    // 顶部文字
    _text(canvas, '每日跑步', const Offset(48, 54), 26, _c(AppPalette.slate1),
        weight: FontWeight.w600);
    _text(canvas, dateLabel, const Offset(48, 100), 22, _c(AppPalette.slate1));
    _text(canvas, (session.distanceMeters / 1000).toStringAsFixed(2),
        const Offset(48, 150), 96, _c(AppPalette.slate1),
        weight: FontWeight.w600);
    _text(canvas, 'km', const Offset(330, 212), 32, _c(AppPalette.slate1));

    // 数据行
    final statY = 760.0;
    _stat(canvas, 48, statY, '用时', _clockText(session.elapsed));
    _stat(canvas, 285, statY, '配速', _paceText(session.averagePaceSecPerKm));
    _stat(canvas, 522, statY, '消耗', '${session.calories} kcal');

    // 分段配速条
    final splits = session.splits.take(4).toList();
    if (splits.isNotEmpty) {
      final max = splits.map((s) => s.seconds).reduce(math.max).toDouble();
      final min = splits.map((s) => s.seconds).reduce(math.min).toDouble();
      final span = (max - min).abs() < 1 ? 1.0 : max - min;
      for (int i = 0; i < splits.length; i++) {
        final s = splits[i];
        final y = 826.0 + i * 20;
        _text(canvas, '${s.kmIndex} km', Offset(48, y), 18, _c(AppPalette.slate11));
        final barX = 120.0;
        final barW = 500.0 * (1 - (s.seconds - min) / span * 0.55);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(barX, y + 3, barW, 10), const Radius.circular(5)),
          Paint()..color = _c(AppPalette.accentEdge),
        );
        _text(canvas, s.paceLabel, Offset(640, y), 18, _c(AppPalette.slate12),
            weight: FontWeight.w600);
      }
    }

    // 记录状态
    final pill = RRect.fromRectAndRadius(
        const Rect.fromLTWH(48, 916, 654, 56), const Radius.circular(28));
    canvas.drawRRect(pill, Paint()..color = _c(AppPalette.accent));
    _text(
      canvas,
      '已记录本次跑步',
      const Offset(375, 932),
      24,
      _c(AppPalette.slate1),
      weight: FontWeight.w600,
      align: TextAlign.center,
      width: 654,
    );
  }

  void _stat(Canvas canvas, double x, double y, String label, String value) {
    _text(canvas, label, Offset(x, y), 20, _c(AppPalette.slate11));
    _text(canvas, value, Offset(x, y + 30), 30, _c(AppPalette.accent),
        weight: FontWeight.w600);
  }

  void _text(
    Canvas canvas,
    String text,
    Offset offset,
    double size,
    Color color, {
    FontWeight weight = FontWeight.w400,
    TextAlign align = TextAlign.left,
    double? width,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: color,
          fontFamily: 'sans-serif',
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: width ?? double.infinity);
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _CardPainter oldDelegate) =>
      oldDelegate.session != session || oldDelegate.dateLabel != dateLabel;
}

/// 把记录卡渲染成 PNG 字节。750×1000 逻辑像素按 2 倍渲染为 1500×2000。
Future<Uint8List> renderShareCardPng(WorkoutSession session,
    {required String dateLabel}) async {
  const double scale = 2;
  const size = Size(750, 1000);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  _CardPainter(session: session, dateLabel: dateLabel).paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
      (size.width * scale).toInt(), (size.height * scale).toInt());
  final byteData =
      await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) throw StateError('记录图渲染失败');
  return byteData.buffer.asUint8List();
}

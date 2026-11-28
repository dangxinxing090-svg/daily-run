import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../theme.dart';
import 'terrain.dart';

Color _c(int v) => Color(v);

String _clockText(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

String _paceText(double secPerKm) {
  if (!secPerKm.isFinite || secPerKm <= 0) return '—';
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
    final frame =
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(36));
    canvas.drawRRect(frame, Paint()..color = _c(AppPalette.sand2));
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = _c(AppPalette.sand6);
    canvas.drawRRect(frame.deflate(1), border);

    _text(canvas, '每日跑步', const Offset(34, 36), 36, _c(AppPalette.sand12),
        weight: FontWeight.w600);
    _text(canvas, dateLabel, const Offset(302, 42), 28, _c(AppPalette.sand11),
        width: 414, align: TextAlign.right);

    final map = Rect.fromLTWH(34, 104, size.width - 68, 694);
    final roundedMap = RRect.fromRectAndRadius(map, const Radius.circular(28));
    canvas.save();
    canvas.clipRRect(roundedMap);
    canvas.translate(map.left, map.top);
    TerrainPainter(points: session.points, track: true).paint(canvas, map.size);
    canvas.restore();
    canvas.drawRRect(roundedMap.deflate(1), border);

    final stats = Rect.fromLTWH(34, 830, size.width - 68, 136);
    final roundedStats =
        RRect.fromRectAndRadius(stats, const Radius.circular(28));
    canvas.drawRRect(roundedStats, Paint()..color = _c(AppPalette.sand1));
    canvas.drawRRect(roundedStats.deflate(1), border);
    final statWidth = stats.width / 3;
    final values = [
      '${(session.distanceMeters / 1000).toStringAsFixed(2)} km',
      _clockText(session.elapsed),
      _paceText(session.averagePaceSecPerKm),
    ];
    const labels = ['距离', '用时', '配速'];
    for (var index = 0; index < labels.length; index++) {
      final x = stats.left + index * statWidth;
      if (index > 0) {
        canvas.drawLine(
            Offset(x, stats.top + 26), Offset(x, stats.bottom - 26), border);
      }
      _text(canvas, labels[index], Offset(x, stats.top + 20), 25,
          _c(AppPalette.sand11),
          width: statWidth, align: TextAlign.center);
      _text(canvas, values[index], Offset(x, stats.top + 60), 39,
          _c(index == 0 ? AppPalette.performText : AppPalette.sand12),
          weight: FontWeight.w600, width: statWidth, align: TextAlign.center);
    }
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
    )..layout(minWidth: width ?? 0, maxWidth: width ?? double.infinity);
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
  picture.dispose();
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) throw StateError('记录图渲染失败');
    return byteData.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

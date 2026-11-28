import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/tracking.dart' show haversineMeters;
import '../theme.dart';
import 'track_path.dart';

Color _c(int v) => Color(v);

/// 湖蓝留白地图底色、绿地与河面，和原型使用相同的比例。
void _paintTerrain(Canvas canvas, Size size) {
  final w = size.width;
  final h = size.height;
  canvas.drawRect(Offset.zero & size, Paint()..color = _c(AppPalette.sage3));

  final green = Paint()..color = _c(AppPalette.sage5);
  final park = Path()
    ..moveTo(0, 0)
    ..cubicTo(w * .35, h * .10, w * .28, h * .48, w * .12, h * .52)
    ..lineTo(0, h * .61)
    ..close();
  canvas.drawPath(park, green);
  canvas.save();
  canvas.translate(w * .86, h * .90);
  canvas.rotate(-.31);
  canvas.drawOval(
    Rect.fromCenter(center: Offset.zero, width: w * .58, height: h * .52),
    green,
  );
  canvas.restore();

  final river = Path()
    ..moveTo(w * .18, h * 1.1)
    ..cubicTo(w * .28, h * .82, w * .63, h * .72, w * 1.05, h * .85);
  canvas.drawPath(
    river,
    Paint()
      ..color = const Color(0xFFD5E7F1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * .19,
  );

  final roads = Path()
    ..moveTo(0, h * .61)
    ..cubicTo(w * .19, h * .69, w * .35, h * .54, w * .39, h * .35)
    ..cubicTo(w * .51, h * .2, w * .68, h * .5, w, h * .09)
    ..moveTo(w * .18, 0)
    ..cubicTo(w * .27, h * .4, w * .24, h * .46, w * .40, h * .59)
    ..cubicTo(w * .54, h * .74, w * .54, h * .82, w * .48, h)
    ..moveTo(w * .83, 0)
    ..cubicTo(w * .65, h * .33, w * .73, h * .8, w * .98, h);
  canvas.drawPath(
    roads,
    Paint()
      ..color = const Color(0xFFFFFEFA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );
}

class TerrainPainter extends CustomPainter {
  final List<TrackPoint> points;
  final bool track;
  final bool live;

  /// 整条轨迹画入进度，0 到 1。结果页用它做「一笔画出来」的入场。
  final double progress;

  /// 最后一段的生长比例，0 到 1。跑中每收到一个点就从 0 长到 1，
  /// 轨迹是一段段接着长出来的，而不是每秒跳一下。
  final double tail;

  TerrainPainter({
    required this.points,
    required this.track,
    this.live = false,
    this.progress = 1,
    this.tail = 1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    _paintTerrain(canvas, size);
    if (!track) {
      canvas.restore();
      return;
    }

    final scale = (size.shortestSide / 220).clamp(.65, 2.5);
    final projection = projectTrack(points, size, pad: 16 * scale);
    final routeColor = _c(AppPalette.accent);
    Offset? currentPosition =
        live && points.length == 1 ? size.center(Offset.zero) : null;
    if (projection.isValid) {
      final pts = projection.points;
      // 折线按段累加长度，画到预算长度为止：整条画入与最后一段生长用同一套算法。
      final segs = <double>[];
      double total = 0;
      for (int i = 1; i < pts.length; i++) {
        final d = (pts[i] - pts[i - 1]).distance;
        segs.add(d);
        total += d;
      }
      double budget = total * progress.clamp(0.0, 1.0);
      if (tail < 1 && progress >= 1 && segs.isNotEmpty) {
        budget = total - segs.last * (1 - tail.clamp(0.0, 1.0));
      }
      final drawn = Path()..moveTo(pts.first.dx, pts.first.dy);
      var tip = pts.first;
      double walked = 0;
      for (int i = 1; i < pts.length; i++) {
        final seg = segs[i - 1];
        if (walked + seg <= budget) {
          tip = pts[i];
          drawn.lineTo(tip.dx, tip.dy);
          walked += seg;
        } else {
          final rest = (budget - walked) / (seg <= 0 ? 1 : seg);
          if (rest > 0) {
            tip = Offset.lerp(pts[i - 1], pts[i], rest)!;
            drawn.lineTo(tip.dx, tip.dy);
          }
          break;
        }
      }
      if (live) currentPosition = tip;
      final stroke = 5 * scale;
      final cap = StrokeCap.round;
      canvas.drawPath(
        drawn,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.8
          ..strokeCap = cap
          ..strokeJoin = StrokeJoin.round
          ..color = _c(AppPalette.sand1).withValues(alpha: 0.95),
      );
      canvas.drawPath(
        drawn,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = cap
          ..strokeJoin = StrokeJoin.round
          ..color = routeColor,
      );
    }

    final dot = 4.4 * scale;
    final origin = projection.isValid ? projection.points.first : null;
    final end = !live && projection.isValid && progress >= 1 && tail >= 1
        ? projection.points.last
        : null;
    if (origin != null && origin != currentPosition) {
      _paintMarker(canvas, origin, dot, routeColor, solid: false);
    }
    if (end != null && (end != origin)) {
      _paintMarker(canvas, end, dot, routeColor, solid: true);
    }
    if (currentPosition != null) {
      _paintMarker(canvas, currentPosition, dot, routeColor, solid: true);
    }
    canvas.restore();
  }

  void _paintMarker(
    Canvas canvas,
    Offset center,
    double radius,
    Color routeColor, {
    required bool solid,
  }) {
    final white = _c(AppPalette.sand1);
    canvas.drawCircle(
        center, radius, Paint()..color = solid ? routeColor : white);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = solid ? white : routeColor
        ..strokeWidth = solid ? 1.6 : 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant TerrainPainter old) =>
      old.points.length != points.length ||
      old.track != track ||
      old.live != live ||
      (old.progress - progress).abs() > 0.001 ||
      (old.tail - tail).abs() > 0.001 ||
      (points.isNotEmpty &&
          old.points.isNotEmpty &&
          old.points.last.ts != points.last.ts);
}

/// 带圆角与细边的地形图容器。主图、缩略图共用。
class TerrainMap extends StatelessWidget {
  final List<TrackPoint> points;
  final bool track;
  final bool live;
  final double radius;
  final double progress;
  final double tail;

  const TerrainMap({
    super.key,
    this.points = const <TrackPoint>[],
    this.track = true,
    this.live = false,
    this.radius = 20,
    this.progress = 1,
    this.tail = 1,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: _c(AppPalette.sand6)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: CustomPaint(
            painter: TerrainPainter(
              points: points,
              track: track,
              live: live,
              progress: progress,
              tail: tail,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      );
}

/// 把进行中的轨迹按固定距离切成若干段，返回每段的秒每公里。
/// 完成后的记录直接用 splits，这里只服务跑中实时态。
List<double> paceBuckets(List<TrackPoint> pts, {double bucketMeters = 500}) {
  if (pts.length < 2) return const <double>[];
  final out = <double>[];
  double acc = 0;
  double boundary = bucketMeters;
  for (int i = 1; i < pts.length; i++) {
    final a = pts[i - 1];
    final b = pts[i];
    if (a.isPauseBoundary || b.isPauseBoundary) continue;
    final d = haversineMeters(a.lat, a.lng, b.lat, b.lng);
    final dt = b.ts.difference(a.ts).inMilliseconds / 1000.0;
    if (d <= 0 || dt <= 0) continue;
    while (acc + d >= boundary) {
      final need = boundary - acc;
      final ratio = need / d;
      out.add(dt * ratio / (need / 1000));
      boundary += bucketMeters;
    }
    acc += d;
  }
  return out;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/tracking.dart' show haversineMeters;
import '../theme.dart';
import 'track_path.dart';

Color _c(int v) => Color(v);

/// 一块不规则柔和色块：11 个控制点带轻微起伏，过相邻中点连二次贝塞尔，
/// 与设计稿里的 bandBlob 同一套几何。
Path _blob(double cx, double cy, double rx, double ry, double seed) {
  const n = 11;
  final pts = <Offset>[];
  for (int i = 0; i < n; i++) {
    final a = i / n * math.pi * 2;
    final wob = 1 +
        0.13 * math.sin(3 * a + seed) +
        0.07 * math.cos(5 * a - seed * 0.7) +
        0.04 * math.sin(2 * a + seed * 0.45);
    pts.add(Offset(cx + rx * wob * math.cos(a), cy + ry * wob * math.sin(a)));
  }
  final mids = <Offset>[
    for (int i = 0; i < n; i++)
      Offset(
        (pts[i].dx + pts[(i + 1) % n].dx) / 2,
        (pts[i].dy + pts[(i + 1) % n].dy) / 2,
      ),
  ];
  final path = Path()..moveTo(mids[n - 1].dx, mids[n - 1].dy);
  for (int i = 0; i < n; i++) {
    path.quadraticBezierTo(pts[i].dx, pts[i].dy, mids[i].dx, mids[i].dy);
  }
  return path..close();
}

List<Path> _mainBands = [];
List<Path> _sideBands = [];
late Path _backdrop;
late Path _backdropSide;
bool _bandsBuilt = false;

void _buildBands() {
  if (_bandsBuilt) return;
  const main = [
    (0.0, 6.0, 166.0, 196.0),
    (-6.0, 0.0, 126.0, 148.0),
    (4.0, -8.0, 88.0, 104.0),
    (-2.0, -4.0, 50.0, 60.0),
  ];
  const side = [
    (0.0, 0.0, 118.0, 132.0),
    (-4.0, -4.0, 78.0, 90.0),
  ];
  _mainBands = [
    for (int i = 0; i < main.length; i++)
      _blob(132 + main[i].$1, 166 + main[i].$2, main[i].$3, main[i].$4, 0.7 + i * 0.63),
  ];
  _sideBands = [
    for (int i = 0; i < side.length; i++)
      _blob(292 + side[i].$1, 300 + side[i].$2, side[i].$3, side[i].$4, 2.2 + i * 0.63),
  ];
  _backdrop = _blob(70, 80, 300, 250, 1.4);
  _backdropSide = _blob(300, 330, 250, 240, 3.2);
  _bandsBuilt = true;
}

/// 色块地形底图，画在 320×360 的视图坐标里，再按 [view] 等比铺满画布。
/// 只用色差分界，不画任何闭合线条；轨迹在最上层，白描边压橙色线。
class TerrainPainter extends CustomPainter {
  final List<TrackPoint> points;
  final Rect view;
  final bool track;

  TerrainPainter({required this.points, required this.view, required this.track});

  @override
  void paint(Canvas canvas, Size size) {
    _buildBands();
    // 只按宽度铺，横向不裁；容器比地形高时把色块纵向拉开填满，
    // 而不是整体放大，否则中间那层会被撑成一整块灰斑。
    final s = size.width / view.width;
    final visibleH = size.height / s;
    final sy = math.min(
        visibleH > view.height ? visibleH / view.height : 1.0, 1.35);
    final far = Rect.fromLTWH(
        view.left - 2000, view.top - 2000, view.width + 4000, view.height + 4000);
    canvas.drawRect(far, Paint()..color = _c(AppPalette.sand2));
    // 先铺一层极淡的鼠尾草底色，主体色块之外不会露出突兀的白边；
    // 再叠两层很淡的背衬做起伏，容器再高也不会显得空。
    canvas.drawRect(far, Paint()..color = _c(AppPalette.sage3).withValues(alpha: 0.34));
    canvas.save();
    canvas.scale(size.width / 320, size.height / 360);
    canvas.drawPath(
        _backdrop, Paint()..color = _c(AppPalette.sage4).withValues(alpha: 0.45));
    canvas.drawPath(
        _backdropSide, Paint()..color = _c(AppPalette.sand4).withValues(alpha: 0.22));
    canvas.restore();
    canvas.translate(
      size.width / 2 - view.center.dx * s,
      size.height / 2 - view.center.dy * s * sy,
    );
    canvas.scale(s, s * sy);
    final inks = <int>[
      AppPalette.sage3,
      AppPalette.sage4,
      AppPalette.sage5,
      AppPalette.sand4,
    ];
    for (int i = 0; i < _mainBands.length; i++) {
      canvas.drawPath(_mainBands[i], Paint()..color = _c(inks[i]));
    }
    final sideInks = <int>[AppPalette.sage3, AppPalette.sage4];
    for (int i = 0; i < _sideBands.length; i++) {
      canvas.drawPath(_sideBands[i], Paint()..color = _c(sideInks[i]));
    }
    if (!track) return;

    // 画布只按宽度铺，纵向可见范围随容器高度变化；
    // 轨迹必须投影到这块真正可见的矩形里，否则窄高的地图会把首尾裁掉。
    final visible = Rect.fromLTWH(
      view.left,
      view.center.dy - size.height / s / 2,
      view.width,
      size.height / s,
    );
    final pad = math.min(16.0, visible.width * 0.08);
    final projection = projectTrack(points, visible.size, pad: pad);
    final origin0 = visible.topLeft;
    if (projection.isValid) {
      final path = Path()
        ..moveTo(projection.points.first.dx + origin0.dx,
            projection.points.first.dy + origin0.dy);
      for (final p in projection.points.skip(1)) {
        path.lineTo(p.dx + origin0.dx, p.dy + origin0.dy);
      }
      final stroke = (3.6 * s).clamp(2.4, 4.6);
      final cap = StrokeCap.round;
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.8
          ..strokeCap = cap
          ..strokeJoin = StrokeJoin.round
          ..color = _c(AppPalette.sand1).withValues(alpha: 0.95),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = cap
          ..strokeJoin = StrokeJoin.round
          ..color = _c(AppPalette.orange9),
      );
    }

    final dot = (4.6 * s).clamp(2.6, 5.2);
    final origin = projection.isValid ? projection.points.first : null;
    final end = projection.isValid ? projection.points.last : null;
    if (origin != null) {
      final c = Offset(origin.dx + origin0.dx, origin.dy + origin0.dy);
      canvas.drawCircle(c, dot, Paint()..color = _c(AppPalette.orange9));
      canvas.drawCircle(
        c,
        dot,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = _c(AppPalette.sand1),
      );
    }
    if (end != null && (end != origin)) {
      final c = Offset(end.dx + origin0.dx, end.dy + origin0.dy);
      canvas.drawCircle(c, dot, Paint()..color = _c(AppPalette.sand1));
      canvas.drawCircle(
        c,
        dot,
        Paint()
          ..color = _c(AppPalette.orange9)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant TerrainPainter old) =>
      old.points.length != points.length ||
      old.track != track ||
      old.view != view ||
      (points.isNotEmpty &&
          old.points.isNotEmpty &&
          old.points.last.ts != points.last.ts);
}

/// 带圆角与细边的地形图容器。主图、缩略图共用。
class TerrainMap extends StatelessWidget {
  final List<TrackPoint> points;
  final Rect view;
  final bool track;
  final double radius;

  const TerrainMap({
    super.key,
    this.points = const <TrackPoint>[],
    this.view = const Rect.fromLTWH(0, 0, 320, 360),
    this.track = true,
    this.radius = AppRules.mapRadius,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(width: AppRules.hairline, color: _c(AppPalette.sand6)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: CustomPaint(
            painter: TerrainPainter(points: points, view: view, track: track),
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

/// 配速曲线：面积填充加橙色折线，最快的那个点上标一个圆点。
class PaceProfilePainter extends CustomPainter {
  final List<double> values;

  PaceProfilePainter({required this.values});

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = _c(AppPalette.sand5);
    for (final f in const [0.25, 0.53, 0.81]) {
      final y = size.height * f;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (values.isEmpty) {
      final y = size.height * 0.78;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = _c(AppPalette.orange9).withValues(alpha: 0.35),
      );
      return;
    }
    // 单段数据只画一条平线，不能从一点拉出整块三角形。
    if (values.length == 1) {
      final y = size.height * 0.5;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7
          ..strokeCap = StrokeCap.round
          ..color = _c(AppPalette.orange9),
      );
      canvas.drawCircle(Offset(size.width - 4, y), 3,
          Paint()..color = _c(AppPalette.orange9));
      return;
    }
    final vs = values;
    double min = vs.first;
    double max = vs.first;
    for (final v in vs) {
      min = math.min(min, v);
      max = math.max(max, v);
    }
    // 至少铺开 20 秒，避免几秒的差距被拉成一条明显的斜坡。
    if (max - min < 20) {
      final mid = (max + min) / 2;
      min = mid - 10;
      max = mid + 10;
    }
    final span = max - min;
    final pad = size.height * 0.14;
    final step = size.width / (vs.length - 1);
    final ys = <double>[
      for (final v in vs) pad + (v - min) / span * (size.height - pad * 2),
    ];
    final line = Path()..moveTo(0, ys.first);
    for (int i = 1; i < ys.length; i++) {
      line.lineTo(i * step, ys[i]);
    }
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = _c(AppPalette.orange3).withValues(alpha: 0.9));
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeJoin = StrokeJoin.round
        ..color = _c(AppPalette.orange9),
    );
    int fastest = 0;
    for (int i = 1; i < vs.length; i++) {
      if (vs[i] < vs[fastest]) fastest = i;
    }
    final c = Offset(fastest * step, ys[fastest]);
    canvas.drawCircle(c, 3.6, Paint()..color = _c(AppPalette.orange9));
    canvas.drawCircle(
      c,
      3.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _c(AppPalette.sand1),
    );
  }

  @override
  bool shouldRepaint(covariant PaceProfilePainter old) => old.values != values;
}

/// 配速曲线的固定高度占位。
class PaceProfile extends StatelessWidget {
  final List<double> values;
  final double height;

  const PaceProfile({super.key, required this.values, this.height = 46});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: CustomPaint(painter: PaceProfilePainter(values: values)),
      );
}

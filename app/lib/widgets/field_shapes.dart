import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../theme.dart';
import 'track_path.dart';

Color _c(int v) => Color(v);

/// 135 度橙色流场渐变，与方向 03 原型一致：
/// --orange-9 到 58% 再渐隐到 --orange-3。
LinearGradient get fieldFlow => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: const [0, 0.58, 1],
      colors: [
        _c(AppPalette.orange9),
        _c(AppPalette.orange9),
        _c(AppPalette.orange3),
      ],
    );

/// 斜切多边形裁剪器。顶点是 0 到 1 的归一化坐标，
/// 由原型里 clip-path polygon 的百分比直接转写。
class PolygonClipper extends CustomClipper<Path> {
  final List<Offset> vertices;

  const PolygonClipper(this.vertices);

  @override
  Path getClip(Size size) {
    final path = Path();
    final first = vertices.first;
    path.moveTo(first.dx * size.width, first.dy * size.height);
    for (final v in vertices.skip(1)) {
      path.lineTo(v.dx * size.width, v.dy * size.height);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant PolygonClipper oldClipper) =>
      oldClipper.vertices != vertices;
}

/// 流带形状，对应原型的 CUT。
class FieldCut {
  /// 从左上冲向右下的主带：polygon(0 18%, 100% 54%, 100% 100%, 0 64%)
  static const bandDown = <Offset>[
    Offset(0, 0.18),
    Offset(1, 0.54),
    Offset(1, 1),
    Offset(0, 0.64),
  ];

  /// 中带：polygon(0 30%, 100% 66%, 100% 90%, 0 54%)
  static const bandMid = <Offset>[
    Offset(0, 0.30),
    Offset(1, 0.66),
    Offset(1, 0.90),
    Offset(0, 0.54),
  ];

  /// 细带：polygon(0 40%, 100% 62%, 100% 76%, 0 54%)
  static const bandThin = <Offset>[
    Offset(0, 0.40),
    Offset(1, 0.62),
    Offset(1, 0.76),
    Offset(0, 0.54),
  ];

  /// 切巨字的流带，只盖住字的上半并斜着收尾：
  /// polygon(0 0, 100% 0, 100% 54%, 0 80%)
  static const cutTop = <Offset>[
    Offset(0, 0),
    Offset(1, 0),
    Offset(1, 0.54),
    Offset(0, 0.80),
  ];

  /// 斜切标签：polygon(9% 0, 100% 0, 91% 100%, 0 100%)
  static const chip = <Offset>[
    Offset(0.09, 0),
    Offset(1, 0),
    Offset(0.91, 1),
    Offset(0, 1),
  ];
}

/// 一条贯穿的橙色流带。
Widget flowBand({
  required List<Offset> vertices,
  required double height,
  double opacity = 1,
  double left = -30,
  double right = -30,
  double top = 0,
}) =>
    Positioned(
      left: left,
      right: right,
      top: top,
      height: height,
      child: ClipPath(
        clipper: PolygonClipper(vertices),
        child: SizedBox.expand(
          child: Opacity(
            opacity: opacity,
            child: Container(decoration: BoxDecoration(gradient: fieldFlow)),
          ),
        ),
      ),
    );

/// 被流带斜切成上下两色的巨字：底层深色完整字，
/// 上层同一位置的白色字只在斜切区域内显示。
Widget cutNumber(
  String text, {
  double size = AppType.display,
  double? width,
}) {
  final textStyle = TextStyle(
    fontSize: size,
    fontWeight: FontWeight.w700,
    fontFeatures: const [FontFeature.tabularFigures()],
    letterSpacing: -size * 0.05,
    height: 1,
  );
  // 量出文字实际宽度，避免流带比数字本身宽出一截形成方块。
  final measure = TextPainter(
    text: TextSpan(text: text, style: textStyle),
    textDirection: TextDirection.ltr,
  )..layout();
  final textWidth = measure.width;
  return SizedBox(
    width: width ?? textWidth,
    height: size,
    child: Stack(
      alignment: Alignment.topLeft,
      children: [
        Text(text, style: textStyle.copyWith(color: _c(AppPalette.slate12))),
        ClipPath(
          clipper: const PolygonClipper(FieldCut.cutTop),
          child: SizedBox.expand(
            child: Container(decoration: BoxDecoration(gradient: fieldFlow)),
          ),
        ),
        ClipPath(
          clipper: const PolygonClipper(FieldCut.cutTop),
          child: SizedBox.expand(
            child:
                Text(text, style: textStyle.copyWith(color: _c(AppPalette.orange1))),
          ),
        ),
      ],
    ),
  );
}

/// 抽象街区线框加轨迹，跑中实时页把轨迹画成流带里的白线。
class FieldTrackPainter extends CustomPainter {
  final List<TrackPoint> points;
  final bool whiteTrack;

  const FieldTrackPainter({
    required this.points,
    this.whiteTrack = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _c(AppPalette.slate7)
      ..strokeWidth = AppRules.hairline;
    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (int i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    if (points.length < 2) return;
    final proj = projectTrack(points, size, pad: 16);
    final path = Path()..moveTo(proj.points.first.dx, proj.points.first.dy);
    for (final p in proj.points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = whiteTrack
            ? _c(AppPalette.orange1)
            : _c(AppPalette.orange9)
        ..strokeWidth = whiteTrack ? 7 : 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final end = proj.end!;
    canvas.drawCircle(
      end,
      whiteTrack ? 7 : 6,
      Paint()
        ..color = whiteTrack
            ? _c(AppPalette.orange1)
            : _c(AppPalette.orange9),
    );
    canvas.drawCircle(
      end,
      whiteTrack ? 2.6 : 2.4,
      Paint()
        ..color = whiteTrack
            ? _c(AppPalette.orange9)
            : _c(AppPalette.orange1),
    );
  }

  @override
  bool shouldRepaint(covariant FieldTrackPainter old) =>
      old.points != points || old.whiteTrack != whiteTrack;
}

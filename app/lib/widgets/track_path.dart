import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import '../domain/models.dart';

/// 把轨迹点投影到给定画布的共享几何，跑中图与记录图都用它，保证两处轨迹一致。
class TrackProjection {
  final List<Offset> points;
  final Offset? start;
  final Offset? end;

  const TrackProjection({
    required this.points,
    required this.start,
    required this.end,
  });

  bool get isValid => points.length >= 2;
}

TrackProjection projectTrack(
  List<TrackPoint> points,
  Size size, {
  double pad = 18,
}) {
  if (points.length < 2) {
    return const TrackProjection(points: [], start: null, end: null);
  }
  double minLat = points.first.lat;
  double maxLat = points.first.lat;
  double minLng = points.first.lng;
  double maxLng = points.first.lng;
  for (final p in points) {
    minLat = math.min(minLat, p.lat);
    maxLat = math.max(maxLat, p.lat);
    minLng = math.min(minLng, p.lng);
    maxLng = math.max(maxLng, p.lng);
  }
  final dx = (maxLng - minLng).abs() < 1e-9 ? 1.0 : maxLng - minLng;
  final dy = (maxLat - minLat).abs() < 1e-9 ? 1.0 : maxLat - minLat;
  final offsets = <Offset>[
    for (final p in points)
      Offset(
        pad + (p.lng - minLng) / dx * (size.width - pad * 2),
        size.height - pad - (p.lat - minLat) / dy * (size.height - pad * 2),
      ),
  ];
  return TrackProjection(
    points: offsets,
    start: offsets.first,
    end: offsets.last,
  );
}

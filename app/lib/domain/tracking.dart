import 'dart:math' as math;

import 'models.dart';

double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  final p1 = lat1 * math.pi / 180;
  final p2 = lat2 * math.pi / 180;
  final dp = p2 - p1;
  final dl = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) *
          math.cos(p2) *
          math.sin(dl / 2) *
          math.sin(dl / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// 运动状态机。页面不直接订阅定位流，只每秒读取 elapsed 与 distanceMeters。
class TrackingManager {
  static const double maxAccuracyMeters = 35.0;
  static const double maxPlausibleSpeedMps = 12.0;
  static const int paceWindowMeters = 500;

  final String sessionId;
  final String? planId;

  SessionStatus status = SessionStatus.idle;
  DateTime? _firstStart;
  DateTime? _startedAt;
  DateTime? _pausedAt;
  Duration _banked = Duration.zero;
  final List<TrackPoint> _points = <TrackPoint>[];
  final List<Duration> _pausedIntervals = <Duration>[];
  double distanceMeters = 0;
  int _seq = 0;

  TrackingManager({required this.sessionId, this.planId});

  List<TrackPoint> get points => List.unmodifiable(_points);

  void start(DateTime now) {
    if (status != SessionStatus.idle) {
      throw StateError('本次运动已经开始了');
    }
    _firstStart = now;
    _startedAt = now;
    status = SessionStatus.recording;
  }

  /// 返回 true 表示点被接受。精度超限、时间倒流、速度突变都直接丢弃。
  bool addPoint({
    required double lat,
    required double lng,
    required DateTime ts,
    double accuracyMeters = 5.0,
    double? speedMps,
    int? heartRateBpm,
  }) {
    if (status != SessionStatus.recording) return false;
    if (accuracyMeters > maxAccuracyMeters) return false;
    if (_points.isNotEmpty) {
      final prev = _points.last;
      final d = haversineMeters(prev.lat, prev.lng, lat, lng);
      final dt = ts.difference(prev.ts).inMilliseconds / 1000.0;
      if (dt <= 0) return false;
      if (d / dt > maxPlausibleSpeedMps) return false;
      distanceMeters += d;
    }
    _points.add(TrackPoint(
      seq: _seq++,
      lat: lat,
      lng: lng,
      ts: ts,
      accuracyMeters: accuracyMeters,
      speedMps: speedMps,
      heartRateBpm: heartRateBpm,
    ));
    return true;
  }

  void pause(DateTime now) {
    if (status != SessionStatus.recording) return;
    _banked += now.difference(_startedAt!);
    _pausedAt = now;
    status = SessionStatus.paused;
    if (_points.isNotEmpty) {
      final p = _points.last;
      _points.add(TrackPoint(
        seq: _seq++,
        lat: p.lat,
        lng: p.lng,
        ts: now,
        accuracyMeters: p.accuracyMeters,
        isPauseBoundary: true,
      ));
    }
  }

  void resume(DateTime now) {
    if (status != SessionStatus.paused) return;
    _pausedIntervals.add(now.difference(_pausedAt!));
    _startedAt = now;
    _pausedAt = null;
    status = SessionStatus.recording;
  }

  Duration elapsed(DateTime now) => _banked +
      (status == SessionStatus.recording
          ? now.difference(_startedAt!)
          : Duration.zero);

  /// 最近约 500 米的滑动窗口配速，避免 GPS 抖动让数字乱跳。
  double currentPaceSecPerKm() {
    if (_points.length < 2) return 0;
    double acc = 0;
    DateTime? windowStart;
    for (int i = _points.length - 1; i > 0; i--) {
      final a = _points[i - 1];
      final b = _points[i];
      if (a.isPauseBoundary || b.isPauseBoundary) continue;
      acc += haversineMeters(a.lat, a.lng, b.lat, b.lng);
      windowStart = a.ts;
      if (acc >= paceWindowMeters) break;
    }
    if (windowStart == null || acc <= 0) return 0;
    final secs = _points.last.ts.difference(windowStart).inSeconds;
    if (secs <= 0) return 0;
    return secs / (acc / 1000);
  }

  List<Split> _buildSplits() {
    final out = <Split>[];
    if (_points.length < 2) return out;
    double acc = 0;
    double boundary = 1000;
    DateTime segStart = _points.first.ts;
    for (int i = 1; i < _points.length; i++) {
      final a = _points[i - 1];
      final b = _points[i];
      if (a.isPauseBoundary || b.isPauseBoundary) continue;
      final d = haversineMeters(a.lat, a.lng, b.lat, b.lng);
      if (d <= 0) continue;
      while (acc + d >= boundary) {
        final need = boundary - acc;
        final ratio = need / d;
        final crossTs = a.ts.add(Duration(
            milliseconds:
                (b.ts.difference(a.ts).inMilliseconds * ratio).round()));
        out.add(Split(
          kmIndex: out.length + 1,
          seconds: crossTs.difference(segStart).inSeconds.toDouble(),
          startTs: segStart,
          endTs: crossTs,
        ));
        segStart = crossTs;
        boundary += 1000;
      }
      acc += d;
    }
    return out;
  }

  WorkoutSession finish(DateTime now) {
    if (status == SessionStatus.paused) {
      _pausedIntervals.add(now.difference(_pausedAt!));
      _pausedAt = null;
    } else if (status == SessionStatus.recording) {
      _banked += now.difference(_startedAt!);
    } else {
      throw StateError('没有进行中的运动');
    }
    status = SessionStatus.finished;
    return WorkoutSession(
      id: sessionId,
      planId: planId,
      startTime: _firstStart!,
      endTime: now,
      elapsed: _banked,
      distanceMeters: distanceMeters,
      calories: (distanceMeters / 1000 * 65).round(),
      points: List<TrackPoint>.from(_points),
      splits: _buildSplits(),
      pausedIntervals: List<Duration>.from(_pausedIntervals),
    );
  }
}

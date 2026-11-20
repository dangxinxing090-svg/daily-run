import 'dart:async';

/// 一次定位结果，坐标保持平台原样，落地到国内地图时再转 GCJ-02。
class TrackFix {
  final double lat;
  final double lng;
  final DateTime ts;
  final double accuracyMeters;
  final double? speedMps;

  const TrackFix({
    required this.lat,
    required this.lng,
    required this.ts,
    required this.accuracyMeters,
    this.speedMps,
  });
}

abstract class LocationSource {
  /// 预览与 Web 用模拟数据，真机用设备定位。
  bool get isSimulated;

  Future<bool> ensurePermission();

  Stream<TrackFix> start();

  Future<void> stop();

  Future<TrackFix?> current();
}

/// Web 预览与桌面预览用的模拟源。点由 AppShell 的定时器生成，
/// 保持原有闭环演示的行为不变。
class SimulatedLocationSource implements LocationSource {
  @override
  bool get isSimulated => true;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Stream<TrackFix> start() => Stream<TrackFix>.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<TrackFix?> current() async => null;
}

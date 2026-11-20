import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'location_types.dart';

/// Android / iOS 真机定位。
/// 运动时启动前台服务并常驻通知，暂停或结束取消订阅后立即停止定位。
/// 不申请 ACCESS_BACKGROUND_LOCATION：前台服务已经能覆盖锁屏记录，
/// 也避免应用市场对后台定位的额外审查。
class DeviceLocationSource implements LocationSource {
  @override
  bool get isSimulated => false;

  LocationSettings get _settings => AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
        intervalDuration: Duration(seconds: 2),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: '正在记录运动',
          notificationText: '每日跑步正在记录轨迹，暂停或结束后立即停止',
          enableWakeLock: false,
          setOngoing: true,
        ),
      );

  @override
  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) return false;
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  @override
  Stream<TrackFix> start() =>
      Geolocator.getPositionStream(locationSettings: _settings).map(
        (p) => TrackFix(
          lat: p.latitude,
          lng: p.longitude,
          ts: p.timestamp,
          accuracyMeters: p.accuracy,
          speedMps: p.speed >= 0 ? p.speed : null,
        ),
      );

  /// geolocator 没有单独的停止接口，取消订阅即停止前台服务。
  @override
  Future<void> stop() async {}

  @override
  Future<TrackFix?> current() async {
    try {
      final p = await Geolocator.getCurrentPosition();
      return TrackFix(
        lat: p.latitude,
        lng: p.longitude,
        ts: p.timestamp,
        accuracyMeters: p.accuracy,
        speedMps: p.speed >= 0 ? p.speed : null,
      );
    } catch (_) {
      return null;
    }
  }
}

LocationSource createLocationSource() => DeviceLocationSource();

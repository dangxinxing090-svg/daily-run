import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'location_types.dart';

/// Android / iOS 真机定位。
/// 运动时启动前台服务并常驻通知，暂停或结束取消订阅后立即停止定位。
/// 不申请 ACCESS_BACKGROUND_LOCATION：前台服务已经能覆盖锁屏记录，
/// 也避免应用市场对后台定位的额外审查。
class DeviceLocationSource implements LocationSource {
  @override
  bool get isSimulated => false;

  LocationSettings get _settings {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.fitness,
        distanceFilter: 3,
        allowBackgroundLocationUpdates: false,
      );
    }
    return AndroidSettings(
      // 国内机型常没有可用的 Google Play 服务，直接走系统 LocationManager 更稳。
      forceLocationManager: true,
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
  }

  @override
  Future<bool> ensurePermission() async {
    // Android 13+ 前台定位服务的常驻通知需要单独授权；
    // 没授权不应阻止开跑，单次定位仍可作为兜底。
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final status = await Permission.notification.status;
        if (status.isDenied) await Permission.notification.request();
        final loc = await Permission.locationWhenInUse.status;
        if (loc.isDenied) await Permission.locationWhenInUse.request();
      } catch (_) {}
    }
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

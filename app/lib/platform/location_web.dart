import 'location_types.dart';

/// Web 与不支持 dart:io 的平台走这一支，不编译任何 Android 定位代码。
LocationSource createLocationSource() => SimulatedLocationSource();

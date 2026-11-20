import 'location_types.dart';
import 'location_web.dart'
    if (dart.library.io) 'location_device.dart' as impl;

export 'location_types.dart';

LocationSource createLocationSource() => impl.createLocationSource();

import 'gallery_types.dart';
import 'gallery_web.dart'
    if (dart.library.io) 'gallery_device.dart' as impl;

export 'gallery_types.dart';

GallerySaver createGallerySaver() => impl.createGallerySaver();

import 'gallery_web.dart' show GallerySaver;
import 'gallery_web.dart'
    if (dart.library.io) 'gallery_device.dart' as impl;

export 'gallery_web.dart';

GallerySaver createGallerySaver() => impl.createGallerySaver();

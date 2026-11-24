import 'dart:typed_data';

import 'package:gal/gal.dart';

import 'gallery_types.dart';

/// 真机把 PNG 写进系统相册。首次保存时插件会按需申请权限。
class DeviceGallerySaver implements GallerySaver {
  @override
  Future<bool> savePng(List<int> bytes, String name) async {
    try {
      await Gal.putImageBytes(Uint8List.fromList(bytes), name: name);
      return true;
    } catch (_) {
      return false;
    }
  }
}

GallerySaver createGallerySaver() => DeviceGallerySaver();

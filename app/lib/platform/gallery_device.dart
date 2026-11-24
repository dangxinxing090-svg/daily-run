import 'dart:typed_data';

import 'package:gal/gal.dart';

/// 真机把 PNG 写进系统相册。首次保存时插件会按需申请权限。
class GallerySaver {
  Future<bool> savePng(Uint8List bytes, String name) async {
    try {
      await Gal.putImageBytes(bytes, name: name);
      return true;
    } catch (_) {
      return false;
    }
  }
}

GallerySaver createGallerySaver() => GallerySaver();

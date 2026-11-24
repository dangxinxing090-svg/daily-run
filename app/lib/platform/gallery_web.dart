import 'dart:typed_data';

/// Web 预览没有系统相册，返回 false，由 UI 提示用户在手机上保存。
class GallerySaver {
  Future<bool> savePng(Uint8List bytes, String name) async => false;
}

GallerySaver createGallerySaver() => GallerySaver();

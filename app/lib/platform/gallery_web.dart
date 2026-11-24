import 'gallery_types.dart';

/// Web 预览没有系统相册，返回 false，由 UI 提示用户在手机上保存。
class WebGallerySaver implements GallerySaver {
  @override
  Future<bool> savePng(List<int> bytes, String name) async => false;
}

GallerySaver createGallerySaver() => WebGallerySaver();

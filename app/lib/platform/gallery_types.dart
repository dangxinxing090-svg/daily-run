/// 把记录图保存到系统相册的抽象，平台实现各自返回这一类型。
abstract class GallerySaver {
  Future<bool> savePng(List<int> bytes, String name);
}

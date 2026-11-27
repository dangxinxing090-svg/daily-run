import 'dart:async';

/// 共享存储备份通道。Web 预览无公共目录，直接降级为空实现。
abstract class BackupStore {
  Future<bool> get available;

  /// 写入固定文件名，返回是否成功。
  Future<bool> write(String json);

  /// 固定文件是否存在。即使内容读不到，也用它避免空备份覆盖旧文件。
  Future<bool> exists();

  /// 自动读取固定文件名。Android 11+ 若文件不再归本应用所有会返回 null。
  Future<String?> read();

  /// 用系统文件选择器读取用户指定的备份文件。
  Future<String?> pick();
}

import 'backup_types.dart';

/// Web 与桌面预览没有公共下载目录，备份能力降级为空。
class NoopBackupStore implements BackupStore {
  @override
  Future<bool> get available async => false;

  @override
  Future<bool> write(String json) async => false;

  @override
  Future<bool> exists() async => false;

  @override
  Future<String?> read() async => null;

  @override
  Future<String?> pick() async => null;
}

BackupStore createBackupStore() => NoopBackupStore();

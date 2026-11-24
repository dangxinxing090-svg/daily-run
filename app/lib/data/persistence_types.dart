import 'session_codec.dart';

/// 本地持久化接口。Dart 侧负责把实体编成 row，存储实现只认 row。
abstract class PersistenceStore {
  Future<void> init();
  Future<LoadedData> loadAll();
  Future<void> upsertPlan(Map<String, dynamic> row);
  Future<void> upsertSession(Map<String, dynamic> row);
  Future<void> upsertCheckIn(Map<String, dynamic> row);
}

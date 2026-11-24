import 'session_codec.dart';

/// 本地持久化接口。Dart 侧负责把实体编成 row，存储实现只认 row。
abstract class PersistenceStore {
  Future<void> init();
  Future<LoadedData> loadAll();
  Future<void> upsertPlan(Map<String, dynamic> row);
  Future<void> upsertSession(Map<String, dynamic> row);
  Future<void> upsertCheckIn(Map<String, dynamic> row);

  /// 删除会话与打卡。删记录时同步清掉引用该会话的打卡，避免日历与列表不一致。
  Future<void> deleteSession(String id);
  Future<void> deleteCheckIns(List<String> ids);

  /// 存储标记，目前只用来记数据版本，保证示例数据只清理一次。
  Future<String?> readMeta(String key);
  Future<void> writeMeta(String key, String value);
}

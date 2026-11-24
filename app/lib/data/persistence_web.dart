import 'persistence_types.dart';
import 'session_codec.dart';

/// Web 与桌面预览的降级存储。SQLite 插件在这些平台不可用，
/// 用同接口的进程内存储保证 UI 流程一致；真机走 SQLite 持久化。
class MemoryPersistenceStore implements PersistenceStore {
  final Map<String, Map<String, dynamic>> _plans = {};
  final Map<String, Map<String, dynamic>> _sessions = {};
  final Map<String, Map<String, dynamic>> _checkIns = {};

  @override
  Future<void> init() async {}

  @override
  Future<LoadedData> loadAll() async => LoadedData(
        plans: _plans.values.map(PlanCodec.fromMap).toList(),
        sessions: _sessions.values.map(WorkoutSessionCodec.fromMap).toList(),
        checkIns: _checkIns.values.map(CheckInCodec.fromMap).toList(),
      );

  @override
  Future<void> upsertPlan(Map<String, dynamic> row) async =>
      _plans[row['id'] as String] = Map<String, dynamic>.from(row);

  @override
  Future<void> upsertSession(Map<String, dynamic> row) async =>
      _sessions[row['id'] as String] = Map<String, dynamic>.from(row);

  @override
  Future<void> upsertCheckIn(Map<String, dynamic> row) async =>
      _checkIns[row['id'] as String] = Map<String, dynamic>.from(row);
}

PersistenceStore createPersistenceStore() => MemoryPersistenceStore();

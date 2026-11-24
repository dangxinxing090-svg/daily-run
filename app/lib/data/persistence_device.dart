import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'persistence_types.dart';
import 'schema.dart';
import 'session_codec.dart';

/// Android / iOS 的 SQLite 实现。三张表，轨迹随会话整行存储，
/// 一次读取即可重建完整轨迹图，不依赖任何网络或账号。
class SqlitePersistenceStore implements PersistenceStore {
  static const int schemaVersion = 2;
  Database? _db;

  Future<Database> get db async {
    final existing = _db;
    if (existing != null) return existing;
    throw StateError('持久化存储尚未初始化');
  }

  @override
  Future<void> init() async {
    if (_db != null) return;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'daily_run.db'),
      version: schemaVersion,
      onCreate: (database, version) => createTables(database),
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) await createMetaTable(database);
      },
    );
  }

  @override
  Future<LoadedData> loadAll() async {
    final database = await db;
    final plans = await database.query('plans');
    final sessions = await database.query('sessions');
    final checkIns = await database.query('check_ins');
    return LoadedData(
      plans: plans.map(PlanCodec.fromMap).toList(),
      sessions: sessions.map(WorkoutSessionCodec.fromMap).toList(),
      checkIns: checkIns.map(CheckInCodec.fromMap).toList(),
    );
  }

  @override
  Future<void> upsertPlan(Map<String, dynamic> row) async {
    await (await db).insert('plans', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> upsertSession(Map<String, dynamic> row) async {
    await (await db).insert('sessions', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> upsertCheckIn(Map<String, dynamic> row) async {
    await (await db).insert('check_ins', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deleteSession(String id) async {
    await (await db).delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> deleteCheckIns(List<String> ids) async {
    if (ids.isEmpty) return;
    final marks = List<String>.filled(ids.length, '?').join(',');
    await (await db)
        .delete('check_ins', where: 'id IN ($marks)', whereArgs: ids);
  }

  @override
  Future<String?> readMeta(String key) async {
    final rows = await (await db)
        .query('meta', columns: ['value'], where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  @override
  Future<void> writeMeta(String key, String value) async {
    await (await db).insert('meta', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

PersistenceStore createPersistenceStore() => SqlitePersistenceStore();

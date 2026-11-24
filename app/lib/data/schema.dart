import 'package:sqflite/sqflite.dart';

/// 三张表的唯一定义。生产库与测试共用，避免两边 SQL 不一致。
const List<String> tableStatements = <String>[
  '''
  CREATE TABLE plans (
    id TEXT PRIMARY KEY,
    date INTEGER NOT NULL,
    start_minutes INTEGER NOT NULL,
    type TEXT NOT NULL,
    target_meters REAL NOT NULL,
    remind_offset INTEGER NOT NULL,
    calendar_event_id TEXT,
    status INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    plan_id TEXT,
    start_ms INTEGER NOT NULL,
    end_ms INTEGER,
    elapsed_ms INTEGER NOT NULL,
    distance_m REAL NOT NULL,
    calories INTEGER NOT NULL,
    points TEXT NOT NULL,
    splits TEXT NOT NULL,
    paused_ms TEXT NOT NULL
  )
  ''',
  '''
  CREATE TABLE check_ins (
    id TEXT PRIMARY KEY,
    date INTEGER NOT NULL,
    session_id TEXT,
    source INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  )
  ''',
];

Future<void> createTables(Database database) async {
  for (final statement in tableStatements) {
    await database.execute(statement);
  }
}

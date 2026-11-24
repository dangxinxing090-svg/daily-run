import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:daily_run/data/schema.dart';
import 'package:daily_run/domain/models.dart';
import 'package:daily_run/domain/repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final t0 = DateTime(2026, 11, 20, 19, 30);
  final t1 = DateTime(2026, 11, 17, 19, 30);

  test('删除一次跑步会连带删掉引用它的打卡，其余记录不动', () async {
    final repo = InMemoryRepository();
    await repo.saveSession(WorkoutSession(id: 's-1', startTime: t0));
    await repo.saveSession(WorkoutSession(id: 's-2', startTime: t1));
    await repo.saveCheckIn(CheckIn(
      id: 'ci-1',
      date: t0,
      sessionId: 's-1',
      source: CheckInSource.auto,
      createdAt: t0,
    ));
    await repo.saveCheckIn(CheckIn(
      id: 'ci-2',
      date: t1,
      sessionId: 's-2',
      source: CheckInSource.auto,
      createdAt: t1,
    ));

    await repo.deleteSession('s-1');

    expect(repo.sessions.map((s) => s.id), ['s-2']);
    expect(repo.checkIns.map((c) => c.id), ['ci-2']);
  });

  test('示例数据只在全是示例时清空，出现真实记录后跳过', () async {
    final repo = InMemoryRepository();
    await repo.saveSession(WorkoutSession(id: 's-demo-1', startTime: t0));
    await repo.saveCheckIn(CheckIn(
      id: 'ci-a',
      date: t0,
      source: CheckInSource.manual,
      createdAt: t0,
    ));

    await repo.purgeDemoData();
    expect(repo.sessions, isEmpty);
    expect(repo.checkIns, isEmpty);

    // 有一条真实跑步之后，再迁移也不许动任何数据。
    await repo.saveSession(WorkoutSession(id: 's-real', startTime: t1));
    await repo.saveCheckIn(CheckIn(
      id: 'ci-b',
      date: t1,
      sessionId: 's-real',
      source: CheckInSource.auto,
      createdAt: t1,
    ));
    await repo.purgeDemoData();
    expect(repo.sessions, hasLength(1));
    expect(repo.checkIns, hasLength(1));
  });

  test('旧库升级到 v2 会补建 meta 表并能读写版本标记', () async {
    final dir = await Directory.systemTemp.createTemp('daily_run_v1');
    final path = p.join(dir.path, 'v1.db');

    final v1 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          for (final s in tableStatements) {
            if (s == metaStatement) continue;
            await db.execute(s);
          }
        },
      ),
    );
    await v1.close();

    final v2 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) => createTables(db),
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) await createMetaTable(db);
        },
      ),
    );
    await v2.insert('meta', {'key': 'data_version', 'value': '2'});
    final rows = await v2.query('meta');
    expect(rows.single['value'], '2');
    await v2.close();

    await dir.delete(recursive: true);
  });
}

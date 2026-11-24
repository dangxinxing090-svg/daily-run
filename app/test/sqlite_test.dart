import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:daily_run/data/session_codec.dart';
import 'package:daily_run/data/schema.dart';
import 'package:daily_run/domain/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('SQLite 真实读写：轨迹与计划跨会话保留', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await createTables(db);

    final t0 = DateTime(2026, 11, 24, 19, 30);
    final session = WorkoutSession(
      id: 's-sql',
      startTime: t0,
      endTime: t0.add(const Duration(minutes: 31)),
      elapsed: const Duration(minutes: 31),
      distanceMeters: 5210,
      calories: 339,
      points: [
        TrackPoint(seq: 0, lat: 39.9, lng: 116.3, ts: t0, accuracyMeters: 5,
            heartRateBpm: 138),
        TrackPoint(seq: 1, lat: 39.901, lng: 116.31,
            ts: t0.add(const Duration(seconds: 60)), accuracyMeters: 5),
      ],
    );
    await db.insert('sessions', WorkoutSessionCodec.toMap(session));
    await db.insert('check_ins', CheckInCodec.toMap(
        CheckIn(id: 'ci-sql', date: t0, source: CheckInSource.auto, createdAt: t0)));
    final plan = Plan(id: 'p-sql', date: t0, startMinutes: 1170,
        type: '间歇跑', targetMeters: 8000, reminderOffsetMinutes: 30);
    await db.insert('plans', PlanCodec.toMap(plan));

    final rows = await db.query('sessions');
    final back = WorkoutSessionCodec.fromMap(rows.single);
    expect(back.points.length, 2);
    expect(back.points.first.heartRateBpm, 138);
    expect(back.distanceMeters, 5210);
    final planRows = await db.query('plans');
    expect(PlanCodec.fromMap(planRows.single).type, '间歇跑');
    final checkRows = await db.query('check_ins');
    expect(checkRows.length, 1);
    await db.close();
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:daily_run/domain/checkin.dart';
import 'package:daily_run/domain/models.dart';
import 'package:daily_run/domain/plan_service.dart';
import 'package:daily_run/domain/tracking.dart';

void main() {
  final t0 = DateTime(2026, 11, 6, 19, 30);

  Plan plan() => Plan(
        id: 'p1',
        date: t0,
        startMinutes: 19 * 60 + 30,
        type: '轻松跑',
        targetMeters: 5000,
        reminderOffsetMinutes: 15,
      );

  group('日历与提醒桥接', () {
    test('计划生成完整事项并按事件 ID 更新删除', () async {
      final bridge = MemoryPlanBridge();
      final service = PlanService(bridge);
      final p = Plan(
        id: 'p1',
        date: t0,
        startMinutes: 19 * 60 + 30,
        type: '轻松跑',
        targetMeters: 5000,
        reminderOffsetMinutes: 15,
      );
      final event = service.eventFor(p);
      expect(event.start.hour, 19);
      expect(event.start.minute, 30);
      expect(event.end.hour, 20);
      expect(event.end.minute, 0);
      expect(event.reminderMinutes, 15);
      final saved = await service.save(p);
      expect(saved.calendarEventId, 'evt-1');
      expect(bridge.events.length, 1);
      await service.remove(saved);
      expect(bridge.removed, contains('evt-1'));
    });
  });

  group('自动打卡', () {
    test('达到目标 80% 才自动打卡', () {
      final svc = CheckInService();
      final ok = WorkoutSession(
          id: 'a', startTime: t0, distanceMeters: 4210);
      final no = WorkoutSession(
          id: 'b', startTime: t0, distanceMeters: 3900);
      expect(svc.shouldAutoCheckIn(ok, plan()), isTrue);
      expect(svc.shouldAutoCheckIn(no, plan()), isFalse);
      expect(svc.auto(ok, t0).source, CheckInSource.auto);
    });
  });

  group('连续天数', () {
    test('今天还没跑不清零，断一天重新算', () {
      final svc = CheckInService();
      final list = <CheckIn>[
        for (int i = 1; i <= 6; i++) svc.manual(DateTime(2026, 11, i)),
      ];
      expect(svc.streak(list, DateTime(2026, 11, 6)), 6);
      expect(svc.streak(list, DateTime(2026, 11, 7)), 6);
      final broken = [...list, svc.manual(DateTime(2026, 11, 8))];
      expect(svc.streak(broken, DateTime(2026, 11, 8)), 1);
    });
  });

  group('运动状态机', () {
    test('暂停时长不计入，异常点被丢弃', () {
      final m = TrackingManager(sessionId: 's1');
      m.start(t0);
      m.addPoint(lat: 39.9, lng: 116.3, ts: t0);
      m.addPoint(
          lat: 39.9009,
          lng: 116.3,
          ts: t0.add(const Duration(seconds: 60)));
      m.pause(t0.add(const Duration(seconds: 60)));
      m.resume(t0.add(const Duration(seconds: 180)));
      m.addPoint(
          lat: 39.9018,
          lng: 116.3,
          ts: t0.add(const Duration(seconds: 240)));
      final s = m.finish(t0.add(const Duration(seconds: 240)));
      expect(s.elapsed.inSeconds, 120);
      expect(s.pausedIntervals.single.inSeconds, 120);
      expect(s.distanceMeters, greaterThan(190));
    });
  });
}

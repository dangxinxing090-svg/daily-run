// ignore_for_file: avoid_print
// M1 业务内核验证，零外部依赖
// 运行：cd app && dart run tool/verify.dart

import 'package:daily_run/domain/checkin.dart';
import 'package:daily_run/domain/models.dart';
import 'package:daily_run/domain/plan_service.dart';
import 'package:daily_run/domain/repository.dart';
import 'package:daily_run/domain/tracking.dart';
import 'package:daily_run/theme.dart';

int passed = 0;
int failed = 0;

bool near(double a, double b, double tol) => (a - b).abs() <= tol;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    passed++;
    print('PASS  $name${detail.isEmpty ? '' : '  $detail'}');
  } else {
    failed++;
    print('FAIL  $name  $detail');
  }
}

Future<void> main() async {
  final t0 = DateTime(2026, 11, 6, 19, 30);

  final d = haversineMeters(39.9, 116.3, 39.9009, 116.3);
  check('距离计算 0.0009 纬度约 100 米', near(d, 100, 2),
      '实测 ${d.toStringAsFixed(1)} m');

  final plan = Plan(
    id: 'p1',
    date: t0,
    startMinutes: 19 * 60 + 30,
    type: '轻松跑',
    targetMeters: 5000,
    reminderOffsetMinutes: 15,
  );
  check('计划时间 19:30', plan.startLabel == '19:30', plan.startLabel);
  check('提前 15 分钟提醒 19:15',
      plan.remindAt.hour == 19 && plan.remindAt.minute == 15);

  final m = TrackingManager(sessionId: 's1', planId: 'p1');
  m.start(t0);
  for (int i = 0; i <= 3; i++) {
    m.addPoint(
      lat: 39.9 + i * 0.0009,
      lng: 116.3,
      ts: t0.add(Duration(seconds: i * 35)),
    );
  }
  check('四个点累计约 300 米', near(m.distanceMeters, 300, 6),
      '${m.distanceMeters.toStringAsFixed(1)} m');
  check('已用时间 105 秒',
      m.elapsed(t0.add(const Duration(seconds: 105))).inSeconds == 105);
  check(
      '精度超限点被丢弃',
      !m.addPoint(
        lat: 39.9045,
        lng: 116.3,
        ts: t0.add(const Duration(seconds: 140)),
        accuracyMeters: 100,
      ));
  check(
      '瞬移点被丢弃',
      !m.addPoint(
        lat: 40.5,
        lng: 116.3,
        ts: t0.add(const Duration(seconds: 175)),
      ));

  final m2 = TrackingManager(sessionId: 's2');
  m2.start(t0);
  m2.addPoint(lat: 39.9, lng: 116.3, ts: t0);
  m2.addPoint(
      lat: 39.9009, lng: 116.3, ts: t0.add(const Duration(seconds: 60)));
  m2.pause(t0.add(const Duration(seconds: 60)));
  m2.resume(t0.add(const Duration(seconds: 180)));
  m2.addPoint(
      lat: 39.9018, lng: 116.3, ts: t0.add(const Duration(seconds: 240)));
  final s2 = m2.finish(t0.add(const Duration(seconds: 240)));
  check('暂停 120 秒不计入时长', s2.elapsed.inSeconds == 120,
      '${s2.elapsed.inSeconds} s');
  check('暂停区间被记录',
      s2.pausedIntervals.length == 1 && s2.pausedIntervals.first.inSeconds == 120);
  check('结束后状态为 finished', m2.status == SessionStatus.finished);

  final m3 = TrackingManager(sessionId: 's3');
  m3.start(t0);
  for (int i = 0; i <= 6; i++) {
    m3.addPoint(
      lat: 39.9 + i * 0.009,
      lng: 116.3,
      ts: t0.add(Duration(seconds: i * 300)),
    );
  }
  final s3 = m3.finish(t0.add(const Duration(seconds: 1800)));
  check('分段配速生成', s3.splits.length >= 5, '${s3.splits.length} 段');
  check('平均配速可计算', s3.averagePaceSecPerKm > 0,
      s3.averagePaceLabel);

  final svc = CheckInService();
  final good = WorkoutSession(
    id: 'x',
    startTime: t0,
    elapsed: const Duration(minutes: 31),
    distanceMeters: 4210,
  );
  final short = WorkoutSession(
    id: 'y',
    startTime: t0,
    elapsed: const Duration(minutes: 28),
    distanceMeters: 3900,
  );
  check('达到 80% 自动打卡', svc.shouldAutoCheckIn(good, plan));
  check('未达 80% 不自动打卡', !svc.shouldAutoCheckIn(short, plan));
  check('无计划但有有效轨迹也可打卡', svc.shouldAutoCheckIn(good, null));
  check(
      '零距离不打卡',
      !svc.shouldAutoCheckIn(
          WorkoutSession(id: 'z', startTime: t0, distanceMeters: 0), plan));

  final list = <CheckIn>[
    for (int i = 1; i <= 6; i++) svc.manual(DateTime(2026, 11, i)),
  ];
  check('11月1日到6日连续 6 天', svc.streak(list, DateTime(2026, 11, 6)) == 6);
  check('今天还没跑不清零', svc.streak(list, DateTime(2026, 11, 7)) == 6);
  final broken = <CheckIn>[...list, svc.manual(DateTime(2026, 11, 8))];
  check('断一天后从新的一段算起',
      svc.streak(broken, DateTime(2026, 11, 8)) == 1);
  check('11月打卡 6 次', svc.monthCheckInCount(list, 2026, 11) == 6);
  check('完成日集合含 6 号',
      svc.completedDaysInMonth(list, 2026, 11).contains(6));

  final sessions = <WorkoutSession>[
    WorkoutSession(
        id: 'a', startTime: DateTime(2026, 11, 3), distanceMeters: 6300),
    WorkoutSession(
        id: 'b', startTime: DateTime(2026, 10, 31), distanceMeters: 5020),
  ];
  check('11月里程 6.3 km',
      near(svc.monthDistance(sessions, 2026, 11) / 1000, 6.3, 0.001));

  final repo = InMemoryRepository();
  repo.savePlan(plan);
  check('计划按日可取', repo.planFor(DateTime(2026, 11, 6))?.id == 'p1');
  repo.saveCheckIn(svc.auto(good, t0));
  repo.saveCheckIn(svc.manual(t0));
  check('同日打卡去重', repo.checkIns.length == 1);
  check('打卡状态可查', repo.hasCheckIn(DateTime(2026, 11, 6)));
  repo.saveSession(good);
  check('会话可存可取', repo.sessions.length == 1);

  check('色板与排版常量齐备',
      AppPalette.orange9 == 0xFFF76B15 &&
          AppType.giant == 72 &&
          AppRules.hairline == 0.5 &&
          AppCut.skewX < 0);

  final bridge = MemoryPlanBridge();
  final planSvc = PlanService(bridge);
  final ev = planSvc.eventFor(plan);
  check('日历事项 19:30 开始', ev.start.hour == 19 && ev.start.minute == 30);
  check('5 km 按 6 分配速排到 20:00', ev.end.hour == 20 && ev.end.minute == 0);
  check('提醒提前 15 分钟', ev.reminderMinutes == 15);
  check('日历标题含类型与距离', ev.title.contains('轻松跑') && ev.title.contains('5.00'));
  final saved = await planSvc.save(plan);
  check('保存后回写日历事件 ID', saved.calendarEventId == 'evt-1', '${saved.calendarEventId}');
  check('桥接收到一条日历事项', bridge.events.length == 1);
  await planSvc.save(saved);
  check('更新时带上已有事件 ID', bridge.events.last.id == 'evt-1');
  await planSvc.remove(saved);
  check('删除时按事件 ID 调用', bridge.removed.contains('evt-1'));

  print('\n$passed 项通过，$failed 项失败');
  if (failed > 0) {
    throw StateError('M1 业务内核验证未通过');
  }
}

import 'models.dart';

/// 打卡与统计。连续天数由日期聚合算，不存一个会被写坏的计数字段。
class CheckInService {
  static const double autoThreshold = 0.8;

  bool shouldAutoCheckIn(WorkoutSession session, Plan? plan) {
    if (session.distanceMeters <= 0) return false;
    if (plan == null) return true;
    return session.distanceMeters >= plan.targetMeters * autoThreshold;
  }

  CheckIn auto(WorkoutSession session, DateTime at) => CheckIn(
        id: 'ci-${_key(at)}',
        date: dateOnly(at),
        sessionId: session.id,
        source: CheckInSource.auto,
        createdAt: at,
      );

  CheckIn manual(DateTime at) => CheckIn(
        id: 'ci-${_key(at)}',
        date: dateOnly(at),
        source: CheckInSource.manual,
        createdAt: at,
      );

  /// 今天还没跑不清零，从昨天继续算。
  int streak(List<CheckIn> all, DateTime today) {
    final days = <DateTime>{};
    for (final c in all) {
      days.add(dateOnly(c.date));
    }
    var d = dateOnly(today);
    if (!days.contains(d)) {
      d = d.subtract(const Duration(days: 1));
    }
    var n = 0;
    while (days.contains(d)) {
      n++;
      d = d.subtract(const Duration(days: 1));
    }
    return n;
  }

  int monthCheckInCount(List<CheckIn> all, int year, int month) => all
      .where((c) => c.date.year == year && c.date.month == month)
      .map((c) => dateOnly(c.date))
      .toSet()
      .length;

  double monthDistance(
          List<WorkoutSession> sessions, int year, int month) =>
      sessions
          .where((s) => s.startTime.year == year && s.startTime.month == month)
          .fold<double>(0, (sum, s) => sum + s.distanceMeters);

  Set<int> completedDaysInMonth(List<CheckIn> all, int year, int month) => all
      .where((c) => c.date.year == year && c.date.month == month)
      .map((c) => c.date.day)
      .toSet();

  String _key(DateTime t) =>
      '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}';
}

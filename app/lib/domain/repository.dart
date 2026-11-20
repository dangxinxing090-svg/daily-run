import 'models.dart';

/// 数据层接口。MVP 用内存实现，落地时换成 SQLite 实现，领域层不用改。
abstract class Repository {
  void savePlan(Plan plan);
  Plan? planFor(DateTime day);
  void saveSession(WorkoutSession session);
  void saveCheckIn(CheckIn checkIn);
  bool hasCheckIn(DateTime day);
  List<Plan> get plans;
  List<WorkoutSession> get sessions;
  List<CheckIn> get checkIns;
}

class InMemoryRepository implements Repository {
  final List<Plan> _plans = <Plan>[];
  final List<WorkoutSession> _sessions = <WorkoutSession>[];
  final List<CheckIn> _checkIns = <CheckIn>[];

  @override
  List<Plan> get plans => List.unmodifiable(_plans);

  @override
  List<WorkoutSession> get sessions => List.unmodifiable(_sessions);

  @override
  List<CheckIn> get checkIns => List.unmodifiable(_checkIns);

  @override
  void savePlan(Plan plan) {
    final i = _plans.indexWhere((p) => p.id == plan.id);
    if (i >= 0) {
      _plans[i] = plan;
    } else {
      _plans.add(plan);
    }
  }

  @override
  Plan? planFor(DateTime day) {
    final d = dateOnly(day);
    for (final p in _plans) {
      if (dateOnly(p.date) == d) return p;
    }
    return null;
  }

  @override
  void saveSession(WorkoutSession session) {
    final i = _sessions.indexWhere((s) => s.id == session.id);
    if (i >= 0) {
      _sessions[i] = session;
    } else {
      _sessions.add(session);
    }
  }

  @override
  void saveCheckIn(CheckIn checkIn) {
    final d = dateOnly(checkIn.date);
    final i = _checkIns.indexWhere((c) => dateOnly(c.date) == d);
    if (i >= 0) {
      _checkIns[i] = checkIn;
    } else {
      _checkIns.add(checkIn);
    }
  }

  @override
  bool hasCheckIn(DateTime day) {
    final d = dateOnly(day);
    return _checkIns.any((c) => dateOnly(c.date) == d);
  }
}

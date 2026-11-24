import '../data/persistence_types.dart';
import '../data/session_codec.dart';
import 'models.dart';

/// 数据层接口。读取保持同步（UI 直接读内存），写入走异步落盘。
abstract class Repository {
  /// 打开存储并加载历史数据。必须在任何读取前调用。
  Future<void> init();

  Future<void> savePlan(Plan plan);
  Future<void> saveSession(WorkoutSession session);
  Future<void> saveCheckIn(CheckIn checkIn);

  Plan? planFor(DateTime day);
  bool hasCheckIn(DateTime day);
  List<Plan> get plans;
  List<WorkoutSession> get sessions;
  List<CheckIn> get checkIns;
}

/// 纯内存实现，用于领域层验证与单元测试。
class InMemoryRepository implements Repository {
  final List<Plan> _plans = <Plan>[];
  final List<WorkoutSession> _sessions = <WorkoutSession>[];
  final List<CheckIn> _checkIns = <CheckIn>[];

  @override
  Future<void> init() async {}

  /// 用持久化快照整体替换内存内容。
  void replaceAll({
    List<Plan>? plans,
    List<WorkoutSession>? sessions,
    List<CheckIn>? checkIns,
  }) {
    _plans
      ..clear()
      ..addAll(plans ?? <Plan>[]);
    _sessions
      ..clear()
      ..addAll(sessions ?? <WorkoutSession>[]);
    _checkIns
      ..clear()
      ..addAll(checkIns ?? <CheckIn>[]);
  }

  @override
  List<Plan> get plans => List.unmodifiable(_plans);

  @override
  List<WorkoutSession> get sessions => List.unmodifiable(_sessions);

  @override
  List<CheckIn> get checkIns => List.unmodifiable(_checkIns);

  @override
  Future<void> savePlan(Plan plan) async {
    final i = _plans.indexWhere((p) => p.id == plan.id);
    if (i >= 0) {
      _plans[i] = plan;
    } else {
      _plans.add(plan);
    }
  }

  @override
  Future<void> saveSession(WorkoutSession session) async {
    final i = _sessions.indexWhere((s) => s.id == session.id);
    if (i >= 0) {
      _sessions[i] = session;
    } else {
      _sessions.add(session);
    }
  }

  @override
  Future<void> saveCheckIn(CheckIn checkIn) async {
    final d = dateOnly(checkIn.date);
    final i = _checkIns.indexWhere((c) => dateOnly(c.date) == d);
    if (i >= 0) {
      _checkIns[i] = checkIn;
    } else {
      _checkIns.add(checkIn);
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
  bool hasCheckIn(DateTime day) {
    final d = dateOnly(day);
    return _checkIns.any((c) => dateOnly(c.date) == d);
  }
}

/// 真机使用的持久化仓储：内存做同步读取，SQLite 做长期保存。
/// 每次写入先更新内存再落盘，UI 立即看到变化，重启后从库恢复。
class PersistentRepository implements Repository {
  final PersistenceStore _store;
  final InMemoryRepository _memory = InMemoryRepository();

  PersistentRepository(this._store);

  @override
  Future<void> init() async {
    await _store.init();
    final data = await _store.loadAll();
    _memory.replaceAll(
      plans: data.plans,
      sessions: data.sessions,
      checkIns: data.checkIns,
    );
  }

  @override
  List<Plan> get plans => _memory.plans;

  @override
  List<WorkoutSession> get sessions => _memory.sessions;

  @override
  List<CheckIn> get checkIns => _memory.checkIns;

  @override
  Plan? planFor(DateTime day) => _memory.planFor(day);

  @override
  bool hasCheckIn(DateTime day) => _memory.hasCheckIn(day);

  @override
  Future<void> savePlan(Plan plan) async {
    await _memory.savePlan(plan);
    await _store.upsertPlan(PlanCodec.toMap(plan));
  }

  @override
  Future<void> saveSession(WorkoutSession session) async {
    await _memory.saveSession(session);
    await _store.upsertSession(WorkoutSessionCodec.toMap(session));
  }

  @override
  Future<void> saveCheckIn(CheckIn checkIn) async {
    await _memory.saveCheckIn(checkIn);
    await _store.upsertCheckIn(CheckInCodec.toMap(checkIn));
  }
}

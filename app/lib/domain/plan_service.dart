import 'models.dart';

/// 一条系统日历事项。提醒交给事件内建的闹钟，由系统负责到点通知，
/// App 不额外常驻后台，也不额外申请通知权限。
class CalendarEventSpec {
  final String? id;
  final String title;
  final DateTime start;
  final DateTime end;
  final String notes;
  final int reminderMinutes;

  const CalendarEventSpec({
    this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.notes,
    required this.reminderMinutes,
  });
}

abstract class PlanBridge {
  /// 返回系统日历事件 ID，供后续更新或删除。
  Future<String> upsertEvent(CalendarEventSpec event);
  Future<void> removeEvent(String eventId);
}

/// 验证与 Web 预览用的内存实现，记录每次调用。
class MemoryPlanBridge implements PlanBridge {
  final List<CalendarEventSpec> events = <CalendarEventSpec>[];
  final List<String> removed = <String>[];
  int _seq = 0;

  @override
  Future<String> upsertEvent(CalendarEventSpec event) async {
    events.add(event);
    return 'evt-${++_seq}';
  }

  @override
  Future<void> removeEvent(String eventId) async {
    removed.add(eventId);
  }
}

class PlanService {
  /// 用默认 6'00" 配速估算事项时长，正式版可由用户历史配速替换。
  static const double defaultPaceSecPerKm = 360;

  final PlanBridge bridge;
  const PlanService(this.bridge);

  CalendarEventSpec eventFor(Plan plan) {
    final km = plan.targetMeters / 1000;
    final start = plan.scheduledAt;
    final end = start.add(
        Duration(seconds: (km * defaultPaceSecPerKm).round()));
    return CalendarEventSpec(
      id: plan.calendarEventId,
      title: '每日跑步 ${plan.type} ${km.toStringAsFixed(2)} km',
      start: start,
      end: end,
      notes: '目标 ${km.toStringAsFixed(2)} km，提前 ${plan.reminderOffsetMinutes} 分钟提醒',
      reminderMinutes: plan.reminderOffsetMinutes,
    );
  }

  Future<Plan> save(Plan plan) async {
    final eventId = await bridge.upsertEvent(eventFor(plan));
    return plan.copyWith(calendarEventId: eventId, status: PlanStatus.pending);
  }

  Future<void> remove(Plan plan) async {
    final id = plan.calendarEventId;
    if (id != null) await bridge.removeEvent(id);
  }
}

// 数据模型，纯 Dart，不依赖 Flutter
// 对应 产品架构.md 的 7 张实体，坐标统一 GCJ-02

enum PlanStatus { pending, inProgress, done, skipped }
enum SessionStatus { idle, recording, paused, finished }
enum CheckInSource { auto, manual }

DateTime dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

class Plan {
  final String id;
  final DateTime date;
  final int startMinutes;
  final String type;
  final double targetMeters;
  final int reminderOffsetMinutes;
  final String? calendarEventId;
  final PlanStatus status;

  const Plan({
    required this.id,
    required this.date,
    required this.startMinutes,
    required this.type,
    required this.targetMeters,
    this.reminderOffsetMinutes = 15,
    this.calendarEventId,
    this.status = PlanStatus.pending,
  });

  String get startLabel {
    final h = startMinutes ~/ 60;
    final m = startMinutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  DateTime get scheduledAt => DateTime(
        date.year,
        date.month,
        date.day,
        startMinutes ~/ 60,
        startMinutes % 60,
      );

  DateTime get remindAt =>
      scheduledAt.subtract(Duration(minutes: reminderOffsetMinutes));

  Plan copyWith({
    PlanStatus? status,
    String? calendarEventId,
    double? targetMeters,
    int? reminderOffsetMinutes,
  }) =>
      Plan(
        id: id,
        date: date,
        startMinutes: startMinutes,
        type: type,
        targetMeters: targetMeters ?? this.targetMeters,
        reminderOffsetMinutes:
            reminderOffsetMinutes ?? this.reminderOffsetMinutes,
        calendarEventId: calendarEventId ?? this.calendarEventId,
        status: status ?? this.status,
      );
}

class TrackPoint {
  final int seq;
  final double lat;
  final double lng;
  final DateTime ts;
  final double accuracyMeters;
  final double? speedMps;
  final bool isPauseBoundary;

  const TrackPoint({
    required this.seq,
    required this.lat,
    required this.lng,
    required this.ts,
    required this.accuracyMeters,
    this.speedMps,
    this.isPauseBoundary = false,
  });
}

class Split {
  final int kmIndex;
  final double seconds;
  final DateTime startTs;
  final DateTime endTs;

  const Split({
    required this.kmIndex,
    required this.seconds,
    required this.startTs,
    required this.endTs,
  });

  String get paceLabel {
    final s = seconds.round();
    return '${s ~/ 60}\'${(s % 60).toString().padLeft(2, '0')}"';
  }
}

class WorkoutSession {
  final String id;
  final String? planId;
  final DateTime startTime;
  DateTime? endTime;
  Duration elapsed;
  double distanceMeters;
  int calories;
  final List<TrackPoint> points;
  final List<Split> splits;
  final List<Duration> pausedIntervals;

  WorkoutSession({
    required this.id,
    required this.startTime,
    this.planId,
    this.endTime,
    this.elapsed = Duration.zero,
    this.distanceMeters = 0,
    this.calories = 0,
    List<TrackPoint>? points,
    List<Split>? splits,
    List<Duration>? pausedIntervals,
  })  : points = points ?? <TrackPoint>[],
        splits = splits ?? <Split>[],
        pausedIntervals = pausedIntervals ?? <Duration>[];

  double get averagePaceSecPerKm => distanceMeters <= 0
      ? 0
      : elapsed.inSeconds / (distanceMeters / 1000);

  String get averagePaceLabel {
    final s = averagePaceSecPerKm.round();
    return '${s ~/ 60}\'${(s % 60).toString().padLeft(2, '0')}"';
  }
}

class CheckIn {
  final String id;
  final DateTime date;
  final String? sessionId;
  final CheckInSource source;
  final DateTime createdAt;

  const CheckIn({
    required this.id,
    required this.date,
    required this.source,
    this.sessionId,
    required this.createdAt,
  });
}

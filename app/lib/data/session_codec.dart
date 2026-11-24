// 数据编解码，纯 Dart，不依赖 Flutter 与数据库。
// 每张实体一张表；轨迹点、分段、暂停区间以 JSON 存在会话行内，
// 这样一次读取就能重建完整轨迹，不需要多表联查。

import 'dart:convert';

import '../domain/models.dart';

class PlanCodec {
  static Map<String, dynamic> toMap(Plan p) => <String, dynamic>{
        'id': p.id,
        'date': p.date.millisecondsSinceEpoch,
        'start_minutes': p.startMinutes,
        'type': p.type,
        'target_meters': p.targetMeters,
        'remind_offset': p.reminderOffsetMinutes,
        'calendar_event_id': p.calendarEventId,
        'status': p.status.index,
      };

  static Plan fromMap(Map<String, dynamic> m) => Plan(
        id: m['id'] as String,
        date: DateTime.fromMillisecondsSinceEpoch(m['date'] as int),
        startMinutes: m['start_minutes'] as int,
        type: m['type'] as String,
        targetMeters: (m['target_meters'] as num).toDouble(),
        reminderOffsetMinutes: m['remind_offset'] as int,
        calendarEventId: m['calendar_event_id'] as String?,
        status: PlanStatus.values[m['status'] as int],
      );
}

class TrackPointCodec {
  static Map<String, dynamic> toMap(TrackPoint p) => <String, dynamic>{
        'seq': p.seq,
        'lat': p.lat,
        'lng': p.lng,
        'ts': p.ts.millisecondsSinceEpoch,
        'acc': p.accuracyMeters,
        'speed': p.speedMps,
        'hr': p.heartRateBpm,
        'pause': p.isPauseBoundary ? 1 : 0,
      };

  static TrackPoint fromMap(Map<String, dynamic> m) => TrackPoint(
        seq: m['seq'] as int,
        lat: (m['lat'] as num).toDouble(),
        lng: (m['lng'] as num).toDouble(),
        ts: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
        accuracyMeters: (m['acc'] as num).toDouble(),
        speedMps: m['speed'] == null ? null : (m['speed'] as num).toDouble(),
        heartRateBpm: m['hr'] as int?,
        isPauseBoundary: (m['pause'] as int?) == 1,
      );
}

class SplitCodec {
  static Map<String, dynamic> toMap(Split s) => <String, dynamic>{
        'km': s.kmIndex,
        'seconds': s.seconds,
        'start': s.startTs.millisecondsSinceEpoch,
        'end': s.endTs.millisecondsSinceEpoch,
      };

  static Split fromMap(Map<String, dynamic> m) => Split(
        kmIndex: m['km'] as int,
        seconds: (m['seconds'] as num).toDouble(),
        startTs: DateTime.fromMillisecondsSinceEpoch(m['start'] as int),
        endTs: DateTime.fromMillisecondsSinceEpoch(m['end'] as int),
      );
}

class WorkoutSessionCodec {
  static Map<String, dynamic> toMap(WorkoutSession s) => <String, dynamic>{
        'id': s.id,
        'plan_id': s.planId,
        'start_ms': s.startTime.millisecondsSinceEpoch,
        'end_ms': s.endTime?.millisecondsSinceEpoch,
        'elapsed_ms': s.elapsed.inMilliseconds,
        'distance_m': s.distanceMeters,
        'calories': s.calories,
        'points': jsonEncode(s.points.map(TrackPointCodec.toMap).toList()),
        'splits': jsonEncode(s.splits.map(SplitCodec.toMap).toList()),
        'paused_ms': jsonEncode(
            s.pausedIntervals.map((d) => d.inMilliseconds).toList()),
      };

  static WorkoutSession fromMap(Map<String, dynamic> m) {
    final rawPoints = jsonDecode(m['points'] as String? ?? '[]') as List;
    final rawSplits = jsonDecode(m['splits'] as String? ?? '[]') as List;
    final rawPaused = jsonDecode(m['paused_ms'] as String? ?? '[]') as List;
    return WorkoutSession(
      id: m['id'] as String,
      planId: m['plan_id'] as String?,
      startTime: DateTime.fromMillisecondsSinceEpoch(m['start_ms'] as int),
      endTime: m['end_ms'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(m['end_ms'] as int),
      elapsed: Duration(milliseconds: m['elapsed_ms'] as int),
      distanceMeters: (m['distance_m'] as num).toDouble(),
      calories: m['calories'] as int,
      points: rawPoints
          .map((e) =>
              TrackPointCodec.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      splits: rawSplits
          .map((e) => SplitCodec.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      pausedIntervals: rawPaused
          .map((e) => Duration(milliseconds: e as int))
          .toList(),
    );
  }
}

class CheckInCodec {
  static Map<String, dynamic> toMap(CheckIn c) => <String, dynamic>{
        'id': c.id,
        'date': c.date.millisecondsSinceEpoch,
        'session_id': c.sessionId,
        'source': c.source.index,
        'created_at': c.createdAt.millisecondsSinceEpoch,
      };

  static CheckIn fromMap(Map<String, dynamic> m) => CheckIn(
        id: m['id'] as String,
        date: DateTime.fromMillisecondsSinceEpoch(m['date'] as int),
        sessionId: m['session_id'] as String?,
        source: CheckInSource.values[m['source'] as int],
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
}

/// 从磁盘加载到内存仓储的一次性快照。
class LoadedData {
  final List<Plan> plans;
  final List<WorkoutSession> sessions;
  final List<CheckIn> checkIns;

  const LoadedData({
    required this.plans,
    required this.sessions,
    required this.checkIns,
  });

  bool get isEmpty => plans.isEmpty && sessions.isEmpty && checkIns.isEmpty;
}

// 跨安装备份的纯 Dart 编解码。
// 备份放在共享存储，格式与数据库解耦；哪怕表结构以后升级，也能靠 schema 字段识别。

import 'dart:convert';

import '../domain/models.dart';
import 'session_codec.dart';

const int backupSchema = 1;
const String backupFileName = 'daily-run-backup.json';
const String backupDirName = '每日跑步';

/// 一次完整备份，包含会话、计划、打卡以及需要跨安装保留的标记。
class BackupEnvelope {
  final int schema;
  final DateTime savedAt;
  final List<WorkoutSession> sessions;
  final List<Plan> plans;
  final List<CheckIn> checkIns;
  final Map<String, String> meta;

  BackupEnvelope({
    this.schema = backupSchema,
    required this.savedAt,
    required this.sessions,
    required this.plans,
    required this.checkIns,
    required this.meta,
  });

  bool get isSupported => schema == backupSchema;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': schema,
        'saved_at': savedAt.millisecondsSinceEpoch,
        'sessions': sessions.map(WorkoutSessionCodec.toMap).toList(),
        'plans': plans.map(PlanCodec.toMap).toList(),
        'check_ins': checkIns.map(CheckInCodec.toMap).toList(),
        'meta': meta,
      };

  String encode() => jsonEncode(toJson());

  factory BackupEnvelope.decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final schema = map['schema'] as int? ?? 0;
    if (schema != backupSchema) {
      throw FormatException('不支持的备份版本 $schema');
    }
    return BackupEnvelope(
      schema: schema,
      savedAt: DateTime.fromMillisecondsSinceEpoch(map['saved_at'] as int? ?? 0),
      sessions: (map['sessions'] as List? ?? const [])
          .map((e) => WorkoutSessionCodec.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      plans: (map['plans'] as List? ?? const [])
          .map((e) => PlanCodec.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      checkIns: (map['check_ins'] as List? ?? const [])
          .map((e) => CheckInCodec.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      meta: Map<String, String>.from(
        (map['meta'] as Map? ?? const {}).map(
          (k, v) => MapEntry<String, String>(k.toString(), v.toString()),
        ),
      ),
    );
  }
}

import 'package:flutter/foundation.dart' show kIsWeb;
import '../domain/models.dart';
import '../domain/repository.dart';
import '../platform/backup.dart';
import 'backup_codec.dart';

/// 跨安装数据备份：写共享目录 + 启动时自动恢复。
/// 删除 App 时内部数据库会被系统清掉，共享目录里的 JSON 不会。
class DataBackupService {
  DataBackupService(this._repo, [BackupStore? store])
      : _store = store ?? createBackupStore();

  final Repository _repo;
  final BackupStore _store;
  DateTime? _lastSavedAt;
  bool _initialized = false;
  bool _sawExternalBackup = false;
  bool _restored = false;
  bool _hadLocalDataAtStart = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _hadLocalDataAtStart = _repo.plans.isNotEmpty ||
        _repo.sessions.isNotEmpty ||
        _repo.checkIns.isNotEmpty;
    try {
      final exists = await _store.exists();
      if (exists) _sawExternalBackup = true;
      final raw = await _store.read();
      if (raw == null || raw.isEmpty) return;
      _sawExternalBackup = true;
      final envelope = BackupEnvelope.decode(raw);
      if (!envelope.isSupported) return;
      // 只在本地完全空白时恢复，不覆盖用户已经产生的数据。
      if (_repo.plans.isNotEmpty ||
          _repo.sessions.isNotEmpty ||
          _repo.checkIns.isNotEmpty) {
        return;
      }
      await _restore(envelope);
      await _repo.writeMeta('backup_initialized', '1');
      _lastSavedAt = envelope.savedAt;
      _restored = true;
    } catch (_) {
      // 备份损坏或系统拒绝读取都不影响启动。
    }
  }

  /// 用户手动指定备份文件，用于 Android 11+ 文件不再归本应用所有的情况。
  Future<bool> restorePicked() async {
    try {
      final raw = await _store.pick();
      if (raw == null || raw.isEmpty) return false;
      final envelope = BackupEnvelope.decode(raw);
      if (!envelope.isSupported) return false;
      await _restore(envelope);
      await _repo.writeMeta('backup_initialized', '1');
      _restored = true;
      await save();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> save() async {
    if (kIsWeb) return false;
    // 外部有备份但当前还没恢复成功时，绝不能用空库覆盖它。
    if (_sawExternalBackup && !_restored && !_hadLocalDataAtStart) return false;
    try {
      final envelope = BackupEnvelope(
        savedAt: DateTime.now(),
        sessions: List<WorkoutSession>.from(_repo.sessions),
        plans: List<Plan>.from(_repo.plans),
        checkIns: List<CheckIn>.from(_repo.checkIns),
        meta: await _repo.readAllMeta(),
      );
      final ok = await _store.write(envelope.encode());
      if (ok) _lastSavedAt = envelope.savedAt;
      return ok;
    } catch (_) {
      return false;
    }
  }

  DateTime? get lastSavedAt => _lastSavedAt;

  bool get sawExternalBackup => _sawExternalBackup;

  Future<void> _restore(BackupEnvelope envelope) async {
    for (final plan in envelope.plans) {
      await _repo.savePlan(plan);
    }
    for (final session in envelope.sessions) {
      await _repo.saveSession(session);
    }
    for (final checkIn in envelope.checkIns) {
      await _repo.saveCheckIn(checkIn);
    }
    for (final entry in envelope.meta.entries) {
      await _repo.writeMeta(entry.key, entry.value);
    }
  }
}

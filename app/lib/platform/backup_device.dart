import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/backup_codec.dart';
import 'backup_types.dart';

/// Android 公共目录备份。同包名同签名重新安装后，系统自动备份会先恢复数据库；
/// 这里的 JSON 是第二道保险，放在用户可见的 Download/每日跑步/ 下。
class MethodChannelBackupStore implements BackupStore {
  static const MethodChannel _channel = MethodChannel('daily_run/backup');

  @override
  Future<bool> get available async => true;

  @override
  Future<bool> write(String json) async {
    try {
      // Android 9 及以下写公共 Download 仍需要存储权限；
      // Android 10+ 走 MediaStore，不需要也不应该申请这个权限。
      if (Platform.isAndroid) {
        final sdk = await _channel.invokeMethod<int>('sdkInt') ?? 0;
        if (sdk < 29) {
          final storage = await Permission.storage.status;
          if (storage.isDenied) {
            final granted = await Permission.storage.request();
            if (!granted.isGranted) return false;
          }
        }
      }
      final ok = await _channel.invokeMethod<bool>('writeBackup', <String, dynamic>{
        'name': backupFileName,
        'dir': backupDirName,
        'json': json,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> exists() async {
    try {
      return await _channel.invokeMethod<bool>('existsBackup', <String, dynamic>{
        'name': backupFileName,
        'dir': backupDirName,
      }) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> read() async {
    try {
      return await _channel.invokeMethod<String>('readBackup', <String, dynamic>{
        'name': backupFileName,
        'dir': backupDirName,
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> pick() async {
    try {
      return await _channel.invokeMethod<String>('pickBackup');
    } catch (_) {
      return null;
    }
  }
}

BackupStore createBackupStore() => MethodChannelBackupStore();

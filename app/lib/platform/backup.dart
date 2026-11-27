import 'backup_types.dart';
import 'backup_web.dart' if (dart.library.io) 'backup_device.dart' as impl;

export 'backup_types.dart';

BackupStore createBackupStore() => impl.createBackupStore();

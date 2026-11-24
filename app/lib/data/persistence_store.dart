import 'persistence_types.dart';
import 'persistence_web.dart'
    if (dart.library.io) 'persistence_device.dart' as impl;

export 'persistence_types.dart';
export 'session_codec.dart';

PersistenceStore createPersistenceStore() => impl.createPersistenceStore();

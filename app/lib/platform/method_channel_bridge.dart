import 'package:flutter/services.dart';

import '../domain/plan_service.dart';

/// 平台通道。Android 由 CalendarProvider 实现，iOS 由 EventKit 实现。
/// 平台没有对应实现时（例如 Web 预览）自动降级，不打断应用内流程。
class MethodChannelPlanBridge implements PlanBridge {
  static const MethodChannel _channel = MethodChannel('daily_run/plan');

  bool nativeAvailable = true;

  Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      nativeAvailable = false;
      return null;
    } on PlatformException {
      nativeAvailable = false;
      return null;
    }
  }

  @override
  Future<String> upsertEvent(CalendarEventSpec event) async {
    final id = await _invoke<String>('upsertEvent', <String, Object?>{
      'id': event.id,
      'title': event.title,
      'start': event.start.millisecondsSinceEpoch,
      'end': event.end.millisecondsSinceEpoch,
      'notes': event.notes,
      'reminderMinutes': event.reminderMinutes,
    });
    return id ?? 'local-${event.start.millisecondsSinceEpoch}';
  }

  @override
  Future<void> removeEvent(String eventId) async {
    if (eventId.startsWith('local-')) return;
    await _invoke<dynamic>('removeEvent', <String, Object?>{'id': eventId});
  }
}

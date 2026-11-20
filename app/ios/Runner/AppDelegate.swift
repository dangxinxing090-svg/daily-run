import Flutter
import UIKit
import EventKit

/**
 * 日历与提醒桥接。
 * 规划运动时把事项写进系统日历，并用 EKAlarm 挂上提前提醒，由系统负责到点通知。
 * 需要完整日历权限：修改或删除自己创建的事项也要能按 ID 找回，write-only 权限读不到已有事件。
 * 本机只有 CommandLineTools、没有完整 Xcode，此文件按 Apple EventKit 官方 API 编写，尚未编译验证。
 */
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let eventStore = EKEventStore()
  private let channelName = "daily_run/plan"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { return }
        Task {
          do {
            let granted = try await self.requestCalendarAccess()
            if !granted {
              DispatchQueue.main.async {
                result(FlutterError(
                  code: "PERMISSION_REQUIRED",
                  message: "需要日历权限才能管理运动计划",
                  details: nil
                ))
              }
              return
            }
            let args = call.arguments as? [String: Any?] ?? [:]
            let value: Any?
            switch call.method {
            case "upsertEvent":
              value = try self.upsertEvent(args)
            case "removeEvent":
              value = try self.removeEvent(args)
            default:
              DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
              return
            }
            DispatchQueue.main.async { result(value) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "CALENDAR_ERROR",
                message: error.localizedDescription,
                details: nil
              ))
            }
          }
        }
      }
    }
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func requestCalendarAccess() async throws -> Bool {
    if #available(iOS 17.0, *) {
      return try await eventStore.requestFullAccessToEvents()
    }
    return try await withCheckedThrowingContinuation { continuation in
      eventStore.requestAccess(to: .event) { granted, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: granted)
        }
      }
    }
  }

  private func upsertEvent(_ args: [String: Any?]) throws -> String {
    guard let title = args["title"] as? String,
          let startMs = (args["start"] as? NSNumber)?.doubleValue,
          let endMs = (args["end"] as? NSNumber)?.doubleValue else {
      throw NSError(
        domain: "daily_run.plan",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "日历事项参数不完整"]
      )
    }

    let existingId = args["id"] as? String
    let event: EKEvent
    if let identifier = existingId,
       let found = eventStore.event(withIdentifier: identifier) {
      event = found
    } else {
      event = EKEvent(eventStore: eventStore)
      event.calendar = eventStore.defaultCalendarForNewEvents
    }

    event.title = title
    event.startDate = Date(timeIntervalSince1970: startMs / 1000.0)
    event.endDate = Date(timeIntervalSince1970: endMs / 1000.0)
    event.notes = args["notes"] as? String

    // 清掉旧闹钟再按最新的提前量重建
    if let alarms = event.alarms {
      for alarm in alarms { event.removeAlarm(alarm) }
    }
    let minutes = (args["reminderMinutes"] as? NSNumber)?.intValue ?? 0
    if minutes > 0 {
      event.addAlarm(EKAlarm(relativeOffset: -Double(minutes * 60)))
    }

    try eventStore.save(event, span: .thisEvent)
    return event.eventIdentifier
  }

  private func removeEvent(_ args: [String: Any?]) throws -> Bool {
    guard let identifier = args["id"] as? String,
          let event = eventStore.event(withIdentifier: identifier) else {
      return false
    }
    try eventStore.remove(event, span: .thisEvent)
    return true
  }
}

package com.dailyrun.app

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

/**
 * 日历与提醒桥接。
 * 规划运动时把事项直接写进系统日历，并用 CalendarContract.Reminders 挂上提前提醒，
 * 由系统负责到点通知，App 不常驻后台，也不额外申请通知权限。
 * 本机没有 Android SDK 构建环境，此文件按官方 CalendarProvider API 编写，尚未编译验证。
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "daily_run/plan"
        private const val REQ_CALENDAR = 4101
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "upsertEvent" -> {
                        if (!hasCalendarPermission()) {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(
                                    Manifest.permission.READ_CALENDAR,
                                    Manifest.permission.WRITE_CALENDAR
                                ),
                                REQ_CALENDAR
                            )
                            result.error("PERMISSION_REQUIRED", "需要日历权限才能写入运动计划", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val eventId = upsertEvent(
                                id = call.argument<String>("id"),
                                title = call.argument<String>("title") ?: "每日跑步",
                                start = call.argument<Number>("start")?.toLong() ?: 0L,
                                end = call.argument<Number>("end")?.toLong() ?: 0L,
                                notes = call.argument<String>("notes") ?: "",
                                minutes = call.argument<Number>("reminderMinutes")?.toInt() ?: 0
                            )
                            result.success(eventId.toString())
                        } catch (e: Exception) {
                            result.error("CALENDAR_ERROR", e.message, null)
                        }
                    }

                    "removeEvent" -> {
                        if (!hasCalendarPermission()) {
                            result.error("PERMISSION_REQUIRED", "需要日历权限才能删除运动计划", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val id = call.argument<String>("id")
                            result.success(id?.let { removeEvent(it) } ?: 0)
                        } catch (e: Exception) {
                            result.error("CALENDAR_ERROR", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun hasCalendarPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    /** 日历 ID 不能硬编码，动态找第一个可写的日历。 */
    private fun writableCalendarId(): Long? {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL
        )
        contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI, projection, null, null, null
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndex(CalendarContract.Calendars._ID)
            val levelIdx = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
            while (cursor.moveToNext()) {
                if (cursor.getInt(levelIdx) >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR) {
                    return cursor.getLong(idIdx)
                }
            }
        }
        return null
    }

    private fun upsertEvent(
        id: String?, title: String, start: Long, end: Long, notes: String, minutes: Int
    ): Long {
        val calId = writableCalendarId() ?: error("没有可写的日历账户")
        val values = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calId)
            put(CalendarContract.Events.TITLE, title)
            put(CalendarContract.Events.DESCRIPTION, notes)
            put(CalendarContract.Events.DTSTART, start)
            put(CalendarContract.Events.DTEND, end)
            put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
            put(CalendarContract.Events.HAS_ALARM, if (minutes > 0) 1 else 0)
        }

        val existing = id?.toLongOrNull()
        val eventId = if (existing != null) {
            val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, existing)
            contentResolver.update(uri, values, null, null)
            existing
        } else {
            val uri = contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
                ?: error("写入日历失败")
            uri.lastPathSegment?.toLongOrNull() ?: error("无法解析日历事件 ID")
        }

        // 先清旧提醒再按最新的提前量重建，避免修改计划后留下幽灵提醒
        contentResolver.delete(
            CalendarContract.Reminders.CONTENT_URI,
            "${CalendarContract.Reminders.EVENT_ID}=?",
            arrayOf(eventId.toString())
        )
        if (minutes > 0) {
            val reminder = ContentValues().apply {
                put(CalendarContract.Reminders.EVENT_ID, eventId)
                put(CalendarContract.Reminders.MINUTES, minutes)
                put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
            }
            contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, reminder)
        }
        return eventId
    }

    private fun removeEvent(id: String): Int {
        val eventId = id.toLongOrNull() ?: return 0
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
        return contentResolver.delete(uri, null, null)
    }
}

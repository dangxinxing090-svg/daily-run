package com.dailyrun.app

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.CalendarContract
import android.provider.MediaStore
import java.io.File
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
        private const val BACKUP_CHANNEL = "daily_run/backup"
        private const val REQ_CALENDAR = 4101
        private const val REQ_PICK_BACKUP = 4201
    }

    private var pendingBackupResult: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK_BACKUP) return
        val result = pendingBackupResult
        pendingBackupResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            result?.success(null)
            return
        }
        try {
            contentResolver.openInputStream(data.data!!)?.bufferedReader(Charsets.UTF_8)?.use {
                result?.success(it.readText())
            } ?: result?.success(null)
        } catch (e: Exception) {
            result?.error("BACKUP_READ_ERROR", e.message, null)
        }
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKUP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "writeBackup" -> {
                        try {
                            val name = call.argument<String>("name") ?: "daily-run-backup.json"
                            val dir = call.argument<String>("dir") ?: "每日跑步"
                            val json = call.argument<String>("json") ?: ""
                            result.success(writeBackup(name, dir, json))
                        } catch (e: Exception) {
                            result.error("BACKUP_WRITE_ERROR", e.message, null)
                        }
                    }
                    "existsBackup" -> {
                        try {
                            val name = call.argument<String>("name") ?: "daily-run-backup.json"
                            val dir = call.argument<String>("dir") ?: "每日跑步"
                            result.success(backupExists(name, dir))
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "readBackup" -> {
                        try {
                            val name = call.argument<String>("name") ?: "daily-run-backup.json"
                            val dir = call.argument<String>("dir") ?: "每日跑步"
                            result.success(readBackup(name, dir))
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    "pickBackup" -> {
                        pendingBackupResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain"))
                        }
                        startActivityForResult(intent, REQ_PICK_BACKUP)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 公共 Download 下的备份文件在卸载后仍保留，重新安装时可读回。 */
    private fun backupFile(name: String, dir: String): File =
        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "$dir/$name")

    private fun writeBackup(name: String, dir: String, json: String): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "application/json")
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$dir")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return false
            return try {
                contentResolver.openOutputStream(uri)?.use { stream ->
                    stream.write(json.toByteArray(Charsets.UTF_8))
                } ?: return false
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                true
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
                false
            }
        }
        val file = backupFile(name, dir)
        file.parentFile?.mkdirs()
        file.writeText(json, Charsets.UTF_8)
        return true
    }

    private fun backupExists(name: String, dir: String): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val projection = arrayOf(MediaStore.Downloads._ID)
            val selection = "${MediaStore.Downloads.DISPLAY_NAME}=?"
            contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                arrayOf(name),
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) return true
            }
            return false
        }
        return backupFile(name, dir).exists()
    }

    private fun readBackup(name: String, dir: String): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val projection = arrayOf(MediaStore.Downloads._ID)
            val selection = "${MediaStore.Downloads.DISPLAY_NAME}=?"
            contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                arrayOf(name),
                "${MediaStore.Downloads.DATE_MODIFIED} DESC"
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID))
                    val uri = ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id)
                    contentResolver.openInputStream(uri)?.bufferedReader(Charsets.UTF_8)?.use {
                        return it.readText()
                    }
                }
            }
            return null
        }
        val file = backupFile(name, dir)
        return if (file.exists()) file.readText(Charsets.UTF_8) else null
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

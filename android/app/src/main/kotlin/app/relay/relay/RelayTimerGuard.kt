package app.relay.relay

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import org.json.JSONObject
import java.util.UUID

/** Android only schedules Dart's next deadline; timing/accounting policy stays in Dart. */
object RelayTimerGuard {
    private const val PREFS = "relay.timer_guard.v1"
    private const val CHANNEL = "relay_timer_checkins"
    const val CHECK_IN_ID = 940100
    const val STOPPED_ID = 940101
    internal const val ALARM_ACTION = "app.relay.relay.guard.ALARM"
    internal const val CONFIRM_ACTION = "app.relay.relay.guard.CONFIRM"
    internal const val STOP_ACTION = "app.relay.relay.guard.STOP"
    private const val ALARM_REQUEST = 940100

    private fun preferences(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun alarmManager(context: Context) = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
    private fun notifications(context: Context) = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    @JvmStatic
    @Synchronized
    fun sync(context: Context, snapshot: Map<String, Any?>) {
        val source = snapshot["context"] as? String ?: return
        if (source != RelayWidgetProvider.currentContext(context)) return
        val prefs = preferences(context)
        if (prefs.getString("context", null) != source) clear(context)
        val raw = snapshot["guard"] as? Map<*, *>
        if (raw == null) {
            cancelAlarm(context)
            cancelCheckIn(context)
            preferences(context).edit().putString("context", source).remove("guard").commit()
            return
        }
        val guard = JSONObject(raw.entries.associate { it.key.toString() to it.value })
        preferences(context).edit().putString("context", source).putString("guard", guard.toString()).commit()
        applySaved(context, source, guard)
    }

    @JvmStatic
    @Synchronized
    fun restore(context: Context) {
        val prefs = preferences(context)
        val source = prefs.getString("context", null) ?: return
        if (source != RelayWidgetProvider.currentContext(context)) { clear(context); return }
        val guard = readGuard(context) ?: return
        applySaved(context, source, guard)
    }

    /** Guard retries only re-read/evaluate saved state; they never replay a user mutation. */
    @JvmStatic
    @Synchronized
    fun retryAfterFailure(context: Context, expectedContext: String) {
        if (expectedContext != RelayWidgetProvider.currentContext(context) || expectedContext != preferences(context).getString("context", null)) return
        val guard = readGuard(context) ?: return
        val sessionStart = session(guard) ?: return
        if (!guard.isNull("stoppedReason") || positiveLong(guard, "nextEventAtMillis") == null) return
        schedule(context, expectedContext, sessionStart, System.currentTimeMillis() + 60_000L)
    }

    @JvmStatic
    @Synchronized
    fun clear(context: Context) {
        cancelAlarm(context)
        notifications(context).cancel(CHECK_IN_ID)
        notifications(context).cancel(STOPPED_ID)
        preferences(context).edit().clear().commit()
    }

    private fun readGuard(context: Context): JSONObject? = try {
        preferences(context).getString("guard", null)?.let { JSONObject(it) }
    } catch (_: Exception) { null }

    private fun positiveLong(data: JSONObject, key: String): Long? =
        if (data.isNull(key)) null else (data.opt(key) as? Number)?.toLong()?.takeIf { it > 0 }

    private fun session(data: JSONObject): String? = data.optString("sessionStart", "").takeIf { it.isNotBlank() }

    private fun applySaved(context: Context, source: String, guard: JSONObject) {
        val sessionStart = session(guard)
        val stoppedReason = guard.optString("stoppedReason", "").takeIf { it.isNotBlank() && it != "null" }
        val stoppedAt = positiveLong(guard, "stoppedAtMillis")
        val nextAt = positiveLong(guard, "nextEventAtMillis")
        if (sessionStart != null && nextAt != null && stoppedReason == null) {
            schedule(context, source, sessionStart, nextAt)
        } else cancelAlarm(context)

        if (stoppedReason != null && stoppedAt != null) {
            cancelCheckIn(context)
            val stamp = "$source:$sessionStart:$stoppedAt"
            if (preferences(context).getString("stoppedPosted", null) != stamp && canNotify(context)) {
                val notification = builder(context).setContentTitle("Timer stopped")
                    .setContentText(stoppedReason)
                    .setStyle(Notification.BigTextStyle().bigText(stoppedReason))
                    .setAutoCancel(true).build()
                notifications(context).notify(STOPPED_ID, notification)
                preferences(context).edit().putString("stoppedPosted", stamp).commit()
            }
            return
        }
        val reminder = positiveLong(guard, "lastReminderAtMillis")
        if (sessionStart == null || reminder == null || nextAt == null) {
            cancelCheckIn(context)
            return
        }
        val status = guard.optString("status", "work")
        val stamp = "$source:$sessionStart:$status:$reminder"
        if (preferences(context).getString("reminderPosted", null) == stamp || !canNotify(context)) return
        val token = UUID.randomUUID().toString()
        preferences(context).edit().putString("notificationToken", token).commit()
        val question = when (status) {
            "baby" -> "Are you still taking care of the baby?"
            "interrupted" -> "Still interrupted?"
            else -> "Are you still working?"
        }
        val notification = builder(context)
            .setContentTitle(question)
            .setContentText("Reply within 15 minutes to keep the timer going, or stop it now.")
            .setStyle(Notification.BigTextStyle().bigText("Reply within 15 minutes to keep the timer going, or stop it now."))
            .setAutoCancel(false)
            .addAction(Notification.Action.Builder(
                Icon.createWithResource(context, R.drawable.ic_notification), "Yes, keep going",
                notificationAction(context, source, sessionStart, token, CONFIRM_ACTION),
            ).build())
            .addAction(Notification.Action.Builder(
                Icon.createWithResource(context, R.drawable.ic_notification), "Stop",
                notificationAction(context, source, sessionStart, token, STOP_ACTION),
            ).build())
            .build()
        notifications(context).notify(CHECK_IN_ID, notification)
        preferences(context).edit().putString("reminderPosted", stamp).commit()
    }

    private fun builder(context: Context): Notification.Builder {
        val manager = notifications(context)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(
            CHANNEL, "Timer check-ins", NotificationManager.IMPORTANCE_HIGH,
        ).apply { description = "Check-ins and automatic timer stops" })
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
        return builder.setSmallIcon(R.drawable.ic_notification)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPriority(Notification.PRIORITY_HIGH)
    }

    private fun canNotify(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        return notifications(context).areNotificationsEnabled()
    }

    private fun schedule(context: Context, source: String, sessionStart: String, deadline: Long) {
        val token = UUID.randomUUID().toString()
        preferences(context).edit().putString("alarmToken", token).commit()
        val pending = PendingIntent.getBroadcast(context, ALARM_REQUEST,
            alarmIntent(context).putExtra("context", source).putExtra("sessionStart", sessionStart).putExtra("guardToken", token),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val at = maxOf(System.currentTimeMillis() + 500L, deadline)
        val manager = alarmManager(context)
        try {
            if (Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms()) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            } else manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        } catch (_: SecurityException) {
            // Permission may be revoked between the capability check and scheduling.
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }

    private fun alarmIntent(context: Context) = Intent(context, RelayTimerGuardReceiver::class.java).apply {
        action = ALARM_ACTION
        data = Uri.parse("relay-guard://alarm")
    }

    private fun cancelAlarm(context: Context) {
        val pending = PendingIntent.getBroadcast(context, ALARM_REQUEST, alarmIntent(context),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
        if (pending != null) { alarmManager(context).cancel(pending); pending.cancel() }
        preferences(context).edit().remove("alarmToken").commit()
    }

    private fun cancelCheckIn(context: Context) {
        notifications(context).cancel(CHECK_IN_ID)
        preferences(context).edit().remove("notificationToken").commit()
    }

    private fun notificationAction(context: Context, source: String, sessionStart: String, token: String, action: String): PendingIntent =
        PendingIntent.getBroadcast(context, if (action == CONFIRM_ACTION) 940102 else 940103,
            Intent(context, RelayTimerGuardReceiver::class.java).apply {
                this.action = action
                data = Uri.parse(if (action == CONFIRM_ACTION) "relay-guard://confirm" else "relay-guard://stop")
                putExtra("context", source)
                putExtra("sessionStart", sessionStart)
                putExtra("guardToken", token)
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /** Validate private pending-intent capabilities before dispatching any timer action. */
    @Synchronized
    internal fun consumeRequest(context: Context, intent: Intent): Map<String, Any?>? {
        val source = intent.getStringExtra("context") ?: return null
        if (source != RelayWidgetProvider.currentContext(context) || source != preferences(context).getString("context", null)) return null
        val guard = readGuard(context) ?: return null
        val sessionStart = intent.getStringExtra("sessionStart") ?: return null
        if (sessionStart != session(guard) || !guard.isNull("stoppedReason")) return null
        val token = intent.getStringExtra("guardToken") ?: return null
        val prefs = preferences(context)
        val action = when (intent.action) {
            ALARM_ACTION -> {
                if (token != prefs.getString("alarmToken", null) || positiveLong(guard, "nextEventAtMillis") == null) return null
                prefs.edit().remove("alarmToken").commit()
                "guard"
            }
            CONFIRM_ACTION, STOP_ACTION -> {
                if (token != prefs.getString("notificationToken", null) || positiveLong(guard, "lastReminderAtMillis") == null) return null
                cancelCheckIn(context)
                if (intent.action == CONFIRM_ACTION) "confirmTimer" else "stopTimer"
            }
            else -> return null
        }
        return mapOf("action" to action, "context" to source, "sessionStart" to sessionStart,
            "expectedStatus" to guard.optString("status", "work"), "requestId" to token)
    }
}

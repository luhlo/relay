package app.relay.relay

import android.Manifest
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
import android.os.Bundle
import androidx.core.app.NotificationManagerCompat
import java.util.UUID

/** A display of the existing snapshot, never a second timer or a foreground service. */
object RelayTimerNotification {
    internal const val CHANNEL = "relay_active_timer"
    internal const val NOTIFICATION_ID = 940110
    // Separate from any real launcher widget, including when none is installed.
    internal const val ACTION_SLOT = -940110
    private const val PREFS = "relay.timer_notification.v1"
    // Public AndroidX/Android extra; compileSdk36 predates the framework36.1 setter.
    internal const val REQUEST_PROMOTED_ONGOING = "android.requestPromotedOngoing"
    internal const val DISMISS_ACTION = "app.relay.relay.timer_notification.DISMISS"

    internal data class State(
        val status: String,
        val label: String,
        val elapsedSeconds: Long,
        val running: Boolean,
        val configured: Boolean,
        val pending: Boolean,
        val needsRefresh: Boolean,
        val message: String,
        val source: String,
        val sessionStart: String?,
    )

    private fun preferences(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun manager(context: Context) = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) manager(context).createNotificationChannel(NotificationChannel(
            CHANNEL, "Active timers", NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Your current work, interruption or baby timer and controls on the lock screen"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        })
    }

    @JvmStatic
    fun settings(context: Context): Map<String, Boolean> {
        ensureChannel(context)
        val granted = Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        return mapOf(
            "enabled" to preferences(context).getBoolean("enabled", true),
            "notificationsAllowed" to (granted && NotificationManagerCompat.from(context).areNotificationsEnabled()),
            "channelEnabled" to (Build.VERSION.SDK_INT < 26 ||
                manager(context).getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE),
        )
    }

    @JvmStatic
    fun setEnabled(context: Context, enabled: Boolean): Map<String, Boolean> {
        return RelayWidgetProvider.setTimerNotificationEnabled(context, enabled)
    }

    /** Visibility preferences and dismissal capabilities share the provider's monitor. */
    internal fun writeEnabled(context: Context, enabled: Boolean) {
        if (enabled) cancelDeleteCapability(context)
        preferences(context).edit().putBoolean("enabled", enabled).apply {
            if (enabled) remove("dismissedSession")
        }.commit()
    }

    private fun deleteIntent(context: Context, token: String): Intent =
        Intent(context, RelayTimerNotificationDismissReceiver::class.java).apply {
            action = DISMISS_ACTION
            data = Uri.parse("relay-timer://dismiss/$token")
            putExtra("dismissToken", token)
        }

    private fun cancelDeleteCapability(context: Context) {
        val prefs = preferences(context)
        prefs.getString("deleteToken", null)?.let { token ->
            PendingIntent.getBroadcast(context, NOTIFICATION_ID, deleteIntent(context, token),
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)?.cancel()
        }
        prefs.edit().remove("deleteToken").remove("displaySession").commit()
    }

    private fun deleteCapability(context: Context, session: String): PendingIntent {
        val prefs = preferences(context)
        if (prefs.getString("displaySession", null) != session) cancelDeleteCapability(context)
        val token = prefs.getString("deleteToken", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("deleteToken", it).putString("displaySession", session).commit()
        }
        return PendingIntent.getBroadcast(context, NOTIFICATION_ID, deleteIntent(context, token),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** A stale delete intent can hide neither a new session nor another account. No timer writes. */
    internal fun consumeDismiss(context: Context, intent: Intent): Boolean {
        if (intent.action != DISMISS_ACTION) return false
        val prefs = preferences(context)
        val token = intent.getStringExtra("dismissToken") ?: return false
        if (token != prefs.getString("deleteToken", null)) return false
        val session = prefs.getString("displaySession", null) ?: return false
        prefs.edit().putString("dismissedSession", session).commit()
        cancelDeleteCapability(context)
        return true
    }

    /** Called only under the provider's shared monitor, with its current capability allocator. */
    internal fun sync(
        context: Context,
        state: State,
        action: (String) -> PendingIntent,
        openApp: () -> PendingIntent,
        revokeActions: () -> Unit,
    ) {
        val settings = settings(context)
        val active = state.configured && state.status in setOf("work", "baby", "interrupted")
        val session = "${state.source}|${state.sessionStart}"
        if (!active || settings.values.any { !it } || preferences(context).getString("dismissedSession", null) == session) {
            manager(context).cancel(NOTIFICATION_ID)
            revokeActions()
            cancelDeleteCapability(context)
            if (!active) preferences(context).edit().remove("dismissedSession").commit()
            return
        }
        val elapsed = state.elapsedSeconds.coerceIn(0L, 100L * 365L * 24L * 60L * 60L)
        val text = when {
            state.needsRefresh -> "Save unconfirmed. Open Relay to refresh."
            state.pending -> "Saving…"
            state.message.isNotBlank() -> state.message
            !state.running -> "Elapsed %02d:%02d:%02d".format(elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
            state.status == "interrupted" -> "Interruption in progress"
            state.status == "baby" -> "Baby time in progress"
            else -> "Focus time in progress"
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
        builder.setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(state.label)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_STOPWATCH)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setPriority(Notification.PRIORITY_LOW)
            .setWhen(System.currentTimeMillis() - elapsed * 1000L)
            .setShowWhen(state.running)
            .setUsesChronometer(state.running)
            .setDeleteIntent(deleteCapability(context, session))
        if (Build.VERSION.SDK_INT >= 24) builder.setChronometerCountDown(false)
        if (Build.VERSION.SDK_INT >= 36 && !state.needsRefresh) {
            // Official AndroidX request extra supports compileSdk36; the framework setter is36.1.
            // Android/Samsung can decline promotion and keep this a normal notification.
            builder.addExtras(Bundle().apply {
                putBoolean(REQUEST_PROMOTED_ONGOING, true)
            })
        }

        fun addAction(title: String, pendingIntent: PendingIntent) {
            val button = Notification.Action.Builder(Icon.createWithResource(context, R.drawable.ic_notification), title, pendingIntent)
            // Timer controls are intentionally usable on the lock screen; no Activity is launched.
            if (Build.VERSION.SDK_INT >= 31) button.setAuthenticationRequired(false)
            builder.addAction(button.build())
        }
        when {
            state.needsRefresh -> {
                val open = openApp()
                builder.setContentIntent(open)
                addAction("Open Relay", open)
            }
            !state.pending -> {
                if (state.status == "work" || state.status == "interrupted") {
                    addAction(if (state.status == "interrupted") "Resume" else "Interruption", action("interruption"))
                }
                addAction("End", action("end"))
            }
        }
        try {
            manager(context).notify(NOTIFICATION_ID, builder.build())
        } catch (_: SecurityException) {
            // Android can revoke notifications between the permission check and posting.
            manager(context).cancel(NOTIFICATION_ID)
            revokeActions()
        }
    }
}

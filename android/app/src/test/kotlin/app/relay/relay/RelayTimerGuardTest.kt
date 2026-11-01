package app.relay.relay

import android.Manifest
import android.app.AlarmManager
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlarmManager

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class RelayTimerGuardTest {
    private lateinit var context: Application
    private val source = "cloud:guard-parent"
    private val started = "2026-11-01T15:00:00.000Z"
    private val deadline get() = System.currentTimeMillis() + 3 * 60 * 60 * 1000L
    private val manager get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val alarms get() = shadowOf(context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)

    @Before
    fun setup() {
        context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("relay.timer_guard.v1", Context.MODE_PRIVATE).edit().clear().commit()
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        ShadowAlarmManager.setCanScheduleExactAlarms(true)
    }

    private fun guard(status: String = "work", next: Long? = deadline, reminder: Long? = null,
        stoppedReason: String? = null, stoppedAt: Long? = null, session: String = started) = mapOf<String, Any?>(
        "sessionStart" to session, "nextEventAtMillis" to next, "lastReminderAtMillis" to reminder,
        "status" to status, "stoppedReason" to stoppedReason, "stoppedAtMillis" to stoppedAt,
    )

    private fun snapshot(guard: Map<String, Any?>?, sourceId: String = source) = RelayWidgetProvider.updateSnapshot(context, mapOf(
        "context" to sourceId, "status" to if (guard?.get("stoppedReason") != null) "idle" else (guard?.get("status") ?: "idle"),
        "childNames" to listOf("Baby 1"), "elapsedSeconds" to 0, "running" to (guard != null), "guard" to guard,
    ))

    @Test
    fun schedulesOneExactIdleAllowedAlarmUsingTheDartDeadline() {
        val at = deadline
        snapshot(guard(next = at))
        var alarm = requireNotNull(alarms.peekNextScheduledAlarm())
        assertEquals(AlarmManager.RTC_WAKEUP, alarm.type)
        assertEquals(at, alarm.triggerAtMs)
        assertEquals(ShadowAlarmManager.WINDOW_EXACT, alarm.windowLengthMs)
        assertTrue(alarm.isAllowWhileIdle)
        assertTrue(shadowOf(alarm.operation).isBroadcast)
        assertTrue(shadowOf(alarm.operation).isImmutable)
        val intent = shadowOf(alarm.operation).savedIntent
        assertEquals(RelayTimerGuardReceiver::class.java.name, intent.component?.className)
        assertEquals(RelayTimerGuard.ALARM_ACTION, intent.action)
        val info = context.packageManager.getReceiverInfo(ComponentName(context, RelayTimerGuardReceiver::class.java), PackageManager.GET_META_DATA)
        assertFalse(info.exported)
        snapshot(guard(next = at + 10000))
        assertEquals(1, alarms.scheduledAlarms.size)
        alarm = requireNotNull(alarms.peekNextScheduledAlarm())
        assertEquals(at + 10000, alarm.triggerAtMs)
        assertNull(shadowOf(context).nextStartedActivity)
    }

    @Test
    fun fallsBackToInexactWhenExactAlarmAccessIsUnavailable() {
        ShadowAlarmManager.setCanScheduleExactAlarms(false)
        snapshot(guard())
        val alarm = requireNotNull(alarms.peekNextScheduledAlarm())
        assertNotEquals(ShadowAlarmManager.WINDOW_EXACT, alarm.windowLengthMs)
        assertTrue(alarm.isAllowWhileIdle)
    }

    @Test
    fun alarmPayloadIsScopedToTheCurrentSessionAndCanOnlyBeConsumedOnce() {
        snapshot(guard())
        val alarm = requireNotNull(alarms.peekNextScheduledAlarm())
        val intent = Intent(shadowOf(alarm.operation).savedIntent)
        val payload = requireNotNull(RelayTimerGuard.consumeRequest(context, intent))
        assertEquals("guard", payload["action"])
        assertEquals(source, payload["context"])
        assertEquals(started, payload["sessionStart"])
        assertNotNull(payload["requestId"])
        assertNull(RelayTimerGuard.consumeRequest(context, Intent(intent)))
        val invented = Intent(RelayTimerGuard.ALARM_ACTION).putExtra("context", source).putExtra("sessionStart", started).putExtra("guardToken", "made-up")
        assertNull(RelayTimerGuard.consumeRequest(context, invented))
    }

    @Test
    fun checkInsUseModeQuestionsAndPrivateBackgroundOnlyActions() {
        for ((status, title) in listOf("work" to "Are you still working?", "baby" to "Are you still taking care of the baby?", "interrupted" to "Still interrupted?")) {
            snapshot(guard(status, reminder = System.currentTimeMillis()))
            val notification = requireNotNull(shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
            assertEquals(title, notification.extras.getString(Notification.EXTRA_TITLE))
            assertEquals(listOf("Yes, keep going", "Stop"), notification.actions.map { it.title.toString() })
            assertNull(notification.contentIntent)
            for (action in notification.actions) {
                assertTrue(shadowOf(action.actionIntent).isBroadcast)
                assertTrue(shadowOf(action.actionIntent).isImmutable)
                assertEquals(RelayTimerGuardReceiver::class.java.name, shadowOf(action.actionIntent).savedIntent.component?.className)
            }
            val yes = Intent(shadowOf(notification.actions[0].actionIntent).savedIntent)
            val stop = Intent(shadowOf(notification.actions[1].actionIntent).savedIntent)
            assertEquals("confirmTimer", RelayTimerGuard.consumeRequest(context, yes)?.get("action"))
            assertNull(RelayTimerGuard.consumeRequest(context, stop))
            assertNull(shadowOf(context).nextStartedActivity)
        }
    }

    @Test
    fun remindersAndAutomaticStopNoticesAreDeduplicated() {
        val stamp = System.currentTimeMillis()
        val state = guard(reminder = stamp)
        snapshot(state)
        val first = requireNotNull(shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
        snapshot(state)
        assertSame(first, shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
        val reason = "No response within 15 minutes. Timer stopped at your last confirmation."
        val stopped = guard(next = null, stoppedReason = reason, stoppedAt = stamp + 1000)
        snapshot(stopped)
        assertNull(shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
        val notice = requireNotNull(shadowOf(manager).getNotification(RelayTimerGuard.STOPPED_ID))
        assertEquals("Timer stopped", notice.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(reason, notice.extras.getString(Notification.EXTRA_TEXT))
        snapshot(stopped)
        assertSame(notice, shadowOf(manager).getNotification(RelayTimerGuard.STOPPED_ID))
        assertTrue(alarms.scheduledAlarms.isEmpty())
    }

    @Test
    fun staleAccountOrSessionNotificationActionsAreRejected() {
        snapshot(guard(reminder = System.currentTimeMillis()))
        var notice = requireNotNull(shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
        val oldSession = Intent(shadowOf(notice.actions[0].actionIntent).savedIntent)
        snapshot(guard(session = "2026-11-01T18:00:00.000Z"))
        assertNull(RelayTimerGuard.consumeRequest(context, oldSession))
        snapshot(guard(reminder = System.currentTimeMillis() + 1000))
        notice = requireNotNull(shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
        val oldAccount = Intent(shadowOf(notice.actions[1].actionIntent).savedIntent)
        snapshot(guard(), sourceId = "cloud:someone-else")
        assertNull(RelayTimerGuard.consumeRequest(context, oldAccount))
    }

    @Test
    fun notificationsRespectPermissionAndCanAppearAfterItIsGranted() {
        shadowOf(context).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        snapshot(guard(reminder = System.currentTimeMillis()))
        assertNull(shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
        assertEquals(1, alarms.scheduledAlarms.size)
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        RelayTimerGuard.restore(context)
        assertNotNull(shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
    }

    @Test
    fun bootRestoresScheduleAndClearCancelsEverything() {
        val at = deadline
        snapshot(guard(next = at, reminder = System.currentTimeMillis()))
        val alarm = requireNotNull(alarms.peekNextScheduledAlarm())
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(requireNotNull(alarm.operation))
        assertTrue(alarms.scheduledAlarms.isEmpty())
        RelayTimerGuardReceiver().onReceive(context, Intent(Intent.ACTION_BOOT_COMPLETED))
        assertEquals(at, alarms.peekNextScheduledAlarm()?.triggerAtMs)
        RelayWidgetProvider.clear(context)
        assertTrue(alarms.scheduledAlarms.isEmpty())
        assertNull(shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
        assertTrue(context.getSharedPreferences("relay.timer_guard.v1", Context.MODE_PRIVATE).all.isEmpty())
    }

    @Test
    fun failedGuardGetsOneFreshReadRetryWithoutRepeatingTheNotification() {
        val state = guard(reminder = System.currentTimeMillis())
        snapshot(state)
        val notice = requireNotNull(shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
        RelayTimerGuard.retryAfterFailure(context, source)
        val retry = requireNotNull(alarms.peekNextScheduledAlarm())
        assertTrue(kotlin.math.abs(retry.triggerAtMs - System.currentTimeMillis() - 60000) < 1000)
        assertEquals(1, alarms.scheduledAlarms.size)
        assertSame(notice, shadowOf(manager).getNotification(RelayTimerGuard.CHECK_IN_ID))
        val payload = requireNotNull(RelayTimerGuard.consumeRequest(context, Intent(shadowOf(retry.operation).savedIntent)))
        assertEquals("guard", payload["action"])
        RelayWidgetProvider.clear(context)
        RelayTimerGuard.retryAfterFailure(context, source)
        assertTrue(alarms.scheduledAlarms.isEmpty())
    }
}

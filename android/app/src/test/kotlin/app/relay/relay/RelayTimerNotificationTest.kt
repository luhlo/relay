package app.relay.relay

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
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
import kotlin.math.abs

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class RelayTimerNotificationTest {
    private lateinit var context: Application
    private val source = "cloud:notification-test"
    private val session = "2026-11-01T15:00:00.000Z"
    private val manager get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val prefs get() = context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE)
    private fun notification() = shadowOf(manager).getNotification(RelayTimerNotification.NOTIFICATION_ID)

    @Before
    fun setup() {
        context = RuntimeEnvironment.getApplication()
        for (name in listOf("relay.home_widget.v1", "relay.timer_notification.v1", "relay.timer_guard.v1")) {
            context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        }
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun snapshot(status: String = "work", elapsed: Int = 300, running: Boolean = status != "idle",
        sourceId: String = source, start: String? = if (status == "idle") null else session,
        label: String? = null, requestId: String? = null) = RelayWidgetProvider.updateSnapshot(context, mapOf(
        "context" to sourceId, "status" to status, "sessionStart" to start,
        "childNames" to listOf("Baby 1", "Baby 2"), "elapsedSeconds" to elapsed,
        "running" to running, "timerLabel" to label,
        "subtitle" to if (status == "baby") "Baby 2" else "", "requestId" to requestId,
    ))

    private fun actionIntent(notification: Notification, index: Int = 0) =
        Intent(shadowOf(notification.actions[index].actionIntent).savedIntent)

    @Test
    fun defaultEnabledWorkNotificationHasNativeStopwatchAndNoWidgetRequirement() {
        assertTrue(AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, RelayWidgetProvider::class.java)).isEmpty())
        snapshot()
        val notice = requireNotNull(notification())
        assertEquals("Work time", notice.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(listOf("Interruption", "End"), notice.actions.map { it.title.toString() })
        assertTrue(notice.extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER))
        assertTrue(notice.extras.getBoolean(Notification.EXTRA_SHOW_WHEN))
        assertFalse(notice.extras.getBoolean(Notification.EXTRA_CHRONOMETER_COUNT_DOWN))
        assertTrue(abs(System.currentTimeMillis() - notice.`when` - 300_000L) < 2000)
        assertEquals(Notification.VISIBILITY_PUBLIC, notice.visibility)
        assertEquals(Notification.CATEGORY_STOPWATCH, notice.category)
        assertTrue(notice.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertTrue(notice.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
        assertEquals(0, notice.flags and Notification.FLAG_FOREGROUND_SERVICE)
        assertNull(notice.contentIntent)
        assertNull(notice.fullScreenIntent)
        assertNull(shadowOf(context).nextStartedActivity)
        val channel = requireNotNull(manager.getNotificationChannel(RelayTimerNotification.CHANNEL))
        assertEquals(NotificationManager.IMPORTANCE_LOW, channel.importance)
        assertEquals(Notification.VISIBILITY_PUBLIC, channel.lockscreenVisibility)
        assertNull(channel.sound)
        assertFalse(channel.shouldVibrate())
        assertNotEquals("relay_timer_checkins", notice.channelId)
    }

    @Test
    fun interruptedTimerUsesInterruptionDurationAndResumeGuard() {
        snapshot("interrupted", elapsed = 35)
        val notice = requireNotNull(notification())
        assertEquals("Interruption time", notice.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(listOf("Resume", "End"), notice.actions.map { it.title.toString() })
        assertTrue(notice.extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER))
        assertTrue(abs(System.currentTimeMillis() - notice.`when` - 35_000L) < 2000)
        val payload = requireNotNull(RelayWidgetProvider.consumeAction(context, actionIntent(notice)))
        assertEquals("interruption", payload["action"])
        assertEquals("interrupted", payload["expectedStatus"])
        assertEquals(session, payload["sessionStart"])
    }

    @Test
    fun babyNameAndAllBabiesHaveOnlyEndAction() {
        for (label in listOf("Baby 2 time", "All babies time", "A very long child name time")) {
            snapshot("baby", label = label)
            val notice = requireNotNull(notification())
            assertEquals(label, notice.extras.getString(Notification.EXTRA_TITLE))
            assertEquals(listOf("End"), notice.actions.map { it.title.toString() })
        }
    }

    @Test
    fun actionsAreExplicitImmutablePrivateBackgroundCapabilitiesAndOneUse() {
        snapshot()
        val notice = requireNotNull(notification())
        val receiver = context.packageManager.getReceiverInfo(ComponentName(context, RelayWidgetActionReceiver::class.java), PackageManager.GET_META_DATA)
        assertFalse(receiver.exported)
        for (action in notice.actions) {
            assertTrue(shadowOf(action.actionIntent).isBroadcast)
            assertTrue(shadowOf(action.actionIntent).isImmutable)
            assertFalse(action.isAuthenticationRequired)
            assertEquals(RelayWidgetActionReceiver::class.java.name, shadowOf(action.actionIntent).savedIntent.component?.className)
        }
        val intent = actionIntent(notice)
        val replay = Intent(intent)
        val payload = requireNotNull(RelayWidgetProvider.consumeAction(context, intent))
        assertEquals("interruption", payload["action"])
        assertEquals(source, payload["context"])
        assertEquals(session, payload["sessionStart"])
        assertEquals("work", payload["expectedStatus"])
        assertNull(RelayWidgetProvider.consumeAction(context, replay))
        assertNull(RelayWidgetProvider.consumeAction(context, Intent(replay).putExtra("widgetToken", "invented")))
        assertNull(shadowOf(context).nextStartedActivity)
    }

    @Test
    fun unchangedRefreshReusesCapabilityAndKeepsTimerAdvancing() {
        snapshot()
        val first = requireNotNull(notification())
        val oldIntent = actionIntent(first)
        val oldToken = oldIntent.getStringExtra("widgetToken")
        snapshot(elapsed = 315)
        val next = requireNotNull(notification())
        assertEquals(oldToken, actionIntent(next).getStringExtra("widgetToken"))
        assertEquals(first.actions[0].actionIntent, next.actions[0].actionIntent)
        assertTrue(abs(System.currentTimeMillis() - next.`when` - 315_000L) < 2000)
        assertNotNull(RelayWidgetProvider.consumeAction(context, oldIntent))
    }

    @Test
    fun oldSessionStatusAndAccountPendingIntentsCannotRetarget() {
        for (change in 0..2) {
            RelayWidgetProvider.clear(context)
            snapshot()
            val old = requireNotNull(notification()).actions[0].actionIntent
            val copied = Intent(shadowOf(old).savedIntent)
            when (change) {
                0 -> snapshot(start = "2026-11-01T18:00:00.000Z")
                1 -> snapshot("interrupted")
                else -> snapshot(sourceId = "cloud:other-test-user")
            }
            assertNull(RelayWidgetProvider.consumeAction(context, copied))
            assertNotEquals(old, requireNotNull(notification()).actions[0].actionIntent)
            try { old.send(); fail("Old session/account PendingIntent must be cancelled") }
            catch (_: PendingIntent.CanceledException) { }
        }
    }

    @Test
    fun notificationStopsOnIdleLogoutAndMalformedUnboundSnapshot() {
        snapshot()
        val oldIntent = actionIntent(requireNotNull(notification()))
        snapshot("idle")
        assertNull(notification())
        assertNull(RelayWidgetProvider.consumeAction(context, oldIntent))
        snapshot()
        RelayWidgetProvider.clear(context)
        assertNull(notification())
        snapshot(start = null)
        assertNull(notification())
        RelayWidgetProvider.updateSnapshot(context, mapOf("context" to ""))
        assertNull(notification())
    }

    @Test
    fun settingOffCancelsAndRevokesControlsAndPersistsThroughLogout() {
        snapshot()
        val old = requireNotNull(notification()).actions[0].actionIntent
        val intent = actionIntent(requireNotNull(notification()))
        assertFalse(RelayTimerNotification.setEnabled(context, false).getValue("enabled"))
        assertNull(notification())
        assertNull(RelayWidgetProvider.consumeAction(context, intent))
        try { old.send(); fail("Disabled notification PendingIntent must be cancelled") }
        catch (_: PendingIntent.CanceledException) { }
        snapshot(elapsed = 320)
        assertNull(notification())
        RelayWidgetProvider.clear(context)
        assertFalse(RelayTimerNotification.settings(context).getValue("enabled"))
        snapshot(elapsed = 350)
        RelayTimerNotification.setEnabled(context, true)
        assertNotNull(notification())
        assertTrue(abs(System.currentTimeMillis() - requireNotNull(notification()).`when` - 350_000L) < 2000)
    }

    @Test
    fun deniedPermissionThenGrantedRepublishesSavedClockWithoutReset() {
        shadowOf(context).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        snapshot()
        assertNull(notification())
        assertTrue(RelayTimerNotification.settings(context).getValue("enabled"))
        assertFalse(RelayTimerNotification.settings(context).getValue("notificationsAllowed"))
        prefs.edit().putLong("savedAt", System.currentTimeMillis() - 45_000L).commit()
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        RelayWidgetProvider.refreshAll(context)
        val notice = requireNotNull(notification())
        assertTrue(abs(System.currentTimeMillis() - notice.`when` - 345_000L) < 2000)
        assertTrue(RelayTimerNotification.settings(context).getValue("notificationsAllowed"))
    }

    @Test
    fun blockedGlobalOrChannelNotificationSettingSuppressesSafely() {
        snapshot()
        shadowOf(manager).setNotificationsEnabled(false)
        RelayWidgetProvider.refreshAll(context)
        assertFalse(RelayTimerNotification.settings(context).getValue("notificationsAllowed"))
        assertNull(notification())
        shadowOf(manager).setNotificationsEnabled(true)
        val channel = manager.getNotificationChannel(RelayTimerNotification.CHANNEL)
        channel.importance = NotificationManager.IMPORTANCE_NONE
        manager.createNotificationChannel(channel)
        RelayWidgetProvider.refreshAll(context)
        assertFalse(RelayTimerNotification.settings(context).getValue("channelEnabled"))
        assertNull(notification())
    }

    @Test
    fun savingFeedbackKeepsClockAndMatchingCompletionRestoresButtons() {
        snapshot()
        val request = requireNotNull(RelayWidgetProvider.consumeAction(context, actionIntent(requireNotNull(notification()))))
        val id = request["requestId"] as String
        assertTrue(RelayWidgetProvider.markPending(context, source, id))
        var notice = requireNotNull(notification())
        assertEquals("Saving…", notice.extras.getString(Notification.EXTRA_TEXT))
        assertTrue(notice.extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER))
        assertTrue(notice.actions.isNullOrEmpty())
        RelayWidgetProvider.reportResult(context, source, null, "unrelated-guard")
        assertTrue(requireNotNull(notification()).actions.isNullOrEmpty())
        snapshot("interrupted", elapsed = 0, requestId = id)
        notice = requireNotNull(notification())
        assertEquals(listOf("Resume", "End"), notice.actions.map { it.title.toString() })
    }

    @Test
    fun unconfirmedSaveHasExplicitRecoveryRatherThanReplayingTimerMutation() {
        snapshot()
        assertTrue(RelayWidgetProvider.markPending(context, source, "pending-test"))
        prefs.edit().putLong("pendingAt", System.currentTimeMillis() - 91_000L).commit()
        RelayWidgetProvider.refreshAll(context)
        val notice = requireNotNull(notification())
        assertEquals(listOf("Open Relay"), notice.actions.map { it.title.toString() })
        assertTrue(shadowOf(notice.actions[0].actionIntent).isActivity)
        assertTrue(notice.extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER))
        assertEquals(MainActivity::class.java.name, shadowOf(requireNotNull(notice.contentIntent)).savedIntent.component?.className)
    }

    @Test
    fun bootRestoresNotificationWithoutAnInstalledWidgetOrStartingActivity() {
        snapshot("baby", elapsed = 600)
        prefs.edit().putLong("savedAt", System.currentTimeMillis() - 60_000L).commit()
        manager.cancel(RelayTimerNotification.NOTIFICATION_ID)
        RelayTimerGuardReceiver().onReceive(context, Intent(Intent.ACTION_BOOT_COMPLETED))
        val notice = requireNotNull(notification())
        assertEquals("Baby 2 time", notice.extras.getString(Notification.EXTRA_TITLE))
        assertTrue(abs(System.currentTimeMillis() - notice.`when` - 660_000L) < 2000)
        assertNull(shadowOf(context).nextStartedActivity)
        snapshot("idle")
        RelayTimerGuardReceiver().onReceive(context, Intent(Intent.ACTION_MY_PACKAGE_REPLACED))
        assertNull(notification())
    }

    @Test
    fun stoppedSnapshotCancelsActiveNotificationAndLeavesSeparateStopNotice() {
        snapshot()
        val stoppedAt = System.currentTimeMillis()
        RelayWidgetProvider.updateSnapshot(context, mapOf(
            "context" to source, "status" to "idle", "sessionStart" to null,
            "guard" to mapOf("sessionStart" to session, "status" to "work", "nextEventAtMillis" to null,
                "lastReminderAtMillis" to null, "stoppedReason" to "No response within 15 minutes.", "stoppedAtMillis" to stoppedAt),
        ))
        assertNull(notification())
        assertNotNull(shadowOf(manager).getNotification(RelayTimerGuard.STOPPED_ID))
    }

    @Test
    @Config(sdk = [28])
    fun preRuntimeNotificationPermissionAndroidStillShowsNativeClock() {
        snapshot("baby")
        assertNotNull(notification())
        assertTrue(RelayTimerNotification.settings(context).getValue("notificationsAllowed"))
        assertTrue(requireNotNull(notification()).extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER))
    }
}

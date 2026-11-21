package app.relay.relay

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class RelayTimerPromotionTest {
    private lateinit var context: Application
    private val source = "cloud:promotion-test"
    private val started = "2026-11-01T15:00:00.000Z"
    private val manager get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private fun notice() = shadowOf(manager).getNotification(RelayTimerNotification.NOTIFICATION_ID)

    @Before
    fun setup() {
        context = RuntimeEnvironment.getApplication()
        for (name in listOf("relay.home_widget.v1", "relay.timer_notification.v1", "relay.timer_guard.v1")) {
            context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        }
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun snapshot(status: String = "work", sourceId: String = source, start: String? = started) =
        RelayWidgetProvider.updateSnapshot(context, mapOf(
            "context" to sourceId, "status" to status, "sessionStart" to if (status == "idle") null else start,
            "childNames" to listOf("Baby 1"), "subtitle" to if (status == "baby") "Baby 1" else "",
            "elapsedSeconds" to 30, "running" to (status != "idle"),
        ))

    private fun dismiss(notification: Notification) {
        RelayTimerNotificationDismissReceiver().onReceive(context, Intent(shadowOf(requireNotNull(notification.deleteIntent)).savedIntent))
    }

    @Test
    fun activeTimerRequestsOfficialPromotionWithoutForegroundServiceOrFakeCategory() {
        snapshot()
        val notification = requireNotNull(notice())
        assertTrue(notification.extras.getBoolean("android.requestPromotedOngoing"))
        // This pinned Android16 image uses the original promotion rules. Keep the
        // ordinary card instead of manufacturing FGS/colorized/call eligibility.
        assertFalse(notification.hasPromotableCharacteristics())
        assertTrue(notification.extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER))
        assertEquals(listOf("Interruption", "End"), notification.actions.map { it.title.toString() })
        assertEquals(Notification.CATEGORY_STOPWATCH, notification.category)
        assertEquals(Notification.BigTextStyle::class.java.name, notification.extras.getString(Notification.EXTRA_TEMPLATE))
        assertEquals(0, notification.flags and Notification.FLAG_FOREGROUND_SERVICE)
        assertFalse(notification.extras.getBoolean(Notification.EXTRA_COLORIZED))
        assertNull(notification.contentView)
        assertNull(notification.bigContentView)
        assertNull(notification.headsUpContentView)
        assertFalse(notification.flags and Notification.FLAG_GROUP_SUMMARY != 0)
        val requested = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS).requestedPermissions.orEmpty()
        assertTrue("android.permission.POST_PROMOTED_NOTIFICATIONS" in requested)
    }

    @Test
    fun dismissalIsPrivateOneUseAndDoesNotStopTrackingOrRepostOnRefresh() {
        snapshot()
        val notification = requireNotNull(notice())
        val delete = requireNotNull(notification.deleteIntent)
        assertTrue(shadowOf(delete).isBroadcast)
        assertTrue(shadowOf(delete).isImmutable)
        val info = context.packageManager.getReceiverInfo(ComponentName(context, RelayTimerNotificationDismissReceiver::class.java), PackageManager.GET_META_DATA)
        assertFalse(info.exported)
        dismiss(notification)
        assertNull(notice())
        assertEquals("work", context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE).getString("status", ""))
        snapshot()
        RelayWidgetProvider.refreshAll(context)
        assertNull(notice())
        snapshot("interrupted")
        assertNull(notice())
        try { delete.send(); fail("Dismissal capability must be one-use") }
        catch (_: PendingIntent.CanceledException) { }
        assertNull(shadowOf(context).nextStartedActivity)
    }

    @Test
    fun staleOrForgedDismissalCannotHideNewSessionOrAnotherAccount() {
        for (change in 0..1) {
            RelayWidgetProvider.clear(context)
            snapshot()
            val old = requireNotNull(notice())
            val oldIntent = Intent(shadowOf(requireNotNull(old.deleteIntent)).savedIntent)
            if (change == 0) snapshot(start = "2026-11-01T18:00:00.000Z")
            else snapshot(sourceId = "cloud:another-test-user")
            RelayTimerNotificationDismissReceiver().onReceive(context, oldIntent)
            assertNotNull(notice())
            RelayTimerNotificationDismissReceiver().onReceive(context, Intent(oldIntent).putExtra("dismissToken", "forged"))
            assertNotNull(notice())
            try { old.deleteIntent.send(); fail("Old context/session dismissal PendingIntent must be cancelled") }
            catch (_: PendingIntent.CanceledException) { }
        }
    }

    @Test
    fun explicitEnableAndNewSessionRestoreDismissedTimer() {
        snapshot()
        dismiss(requireNotNull(notice()))
        assertNull(notice())
        RelayTimerNotification.setEnabled(context, false)
        RelayTimerNotification.setEnabled(context, true)
        assertNotNull(notice())
        dismiss(requireNotNull(notice()))
        snapshot(start = "2026-11-01T18:00:00.000Z")
        assertNotNull(notice())
        dismiss(requireNotNull(notice()))
        RelayWidgetProvider.clear(context)
        snapshot(sourceId = "cloud:another-test-user")
        assertNotNull(notice())
    }

    @Test
    fun dismissalWhileSavingSurvivesTheMatchingSameSessionCompletion() {
        snapshot()
        val action = Intent(shadowOf(requireNotNull(notice()).actions[0].actionIntent).savedIntent)
        val request = requireNotNull(RelayWidgetProvider.consumeAction(context, action))
        val id = request["requestId"] as String
        assertTrue(RelayWidgetProvider.markPending(context, source, id))
        dismiss(requireNotNull(notice()))
        assertNull(notice())
        RelayWidgetProvider.updateSnapshot(context, mapOf(
            "context" to source, "status" to "interrupted", "sessionStart" to started,
            "requestId" to id, "elapsedSeconds" to 0, "running" to true,
            "childNames" to listOf("Baby 1"),
        ))
        val prefs = context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE)
        assertEquals("interrupted", prefs.getString("status", ""))
        assertNull(prefs.getString("pendingRequestId", null))
        assertNull(notice())
    }

    @Test
    fun unconfirmedSaveRecoveryDoesNotRequestPromotionAsAShortcut() {
        snapshot()
        assertTrue(RelayWidgetProvider.markPending(context, source, "test-unconfirmed"))
        context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE).edit()
            .putLong("pendingAt", System.currentTimeMillis() - 91_000L).commit()
        RelayWidgetProvider.refreshAll(context)
        val notification = requireNotNull(notice())
        assertEquals(listOf("Open Relay"), notification.actions.map { it.title.toString() })
        assertFalse(notification.extras.getBoolean("android.requestPromotedOngoing"))
    }

    @Test
    @Config(sdk = [28])
    fun olderAndroidKeepsStandardNotificationAndControls() {
        snapshot()
        val notification = requireNotNull(notice())
        assertFalse(notification.extras.getBoolean("android.requestPromotedOngoing"))
        assertTrue(notification.extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER))
        assertEquals(listOf("Interruption", "End"), notification.actions.map { it.title.toString() })
        assertTrue(notification.actions.all { shadowOf(it.actionIntent).isBroadcast })
    }
}

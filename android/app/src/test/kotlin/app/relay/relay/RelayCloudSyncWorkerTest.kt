package app.relay.relay

import android.app.Application
import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.NetworkType
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class RelayCloudSyncWorkerTest {
    private lateinit var context: Application
    private val source = "cloud:parent-one"
    private val prefs get() = context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE)

    @Before
    fun setup() {
        context = RuntimeEnvironment.getApplication()
        prefs.edit().clear().commit()
    }

    private fun snapshot(
        owner: String = source, pending: Boolean? = null, blocked: Boolean? = null,
    ) {
        val value = mutableMapOf<String, Any?>(
            "context" to owner,
            "status" to "idle",
            "childNames" to listOf("Baby 1"),
        )
        if (pending != null) value["syncPending"] = pending
        if (blocked != null) value["syncBlocked"] = blocked
        RelayWidgetProvider.updateSnapshot(context, value)
    }

    @Test
    fun networkQueueIsAccountScopedAndSeparateFromWidgetActions() {
        val work = RelayCloudSyncWorker.request(source)
        assertEquals(NetworkType.CONNECTED, work.workSpec.constraints.requiredNetworkType)
        assertEquals(source, work.workSpec.input.getString(RelayCloudSyncWorker.CONTEXT_DATA))
        assertEquals(BackoffPolicy.EXPONENTIAL, work.workSpec.backoffPolicy)
        assertEquals(30_000L, work.workSpec.backoffDelayDuration)
        assertNotEquals(RelayWidgetWorker.QUEUE_NAME, RelayCloudSyncWorker.queueName(source))
        assertNotEquals(RelayCloudSyncWorker.queueName(source), RelayCloudSyncWorker.queueName("cloud:parent-two"))
        assertFalse(RelayCloudSyncWorker.queueName(source).contains("parent-one"))
    }

    @Test
    fun staleOrBlockedQueuedJobsSkipTheFlutterEngine() {
        val valid = RelayCloudSyncState(source, true, false, 4L)
        assertTrue(RelayCloudSyncWorker.shouldStart(source, valid))
        assertFalse(RelayCloudSyncWorker.shouldStart("cloud:other", valid))
        assertFalse(RelayCloudSyncWorker.shouldStart("local", valid.copy(source = "local")))
        assertFalse(RelayCloudSyncWorker.shouldStart("cloud:", valid.copy(source = "cloud:")))
        assertFalse(RelayCloudSyncWorker.shouldStart(source, valid.copy(pending = false)))
        assertFalse(RelayCloudSyncWorker.shouldStart(source, valid.copy(blocked = true)))
    }

    @Test
    fun staleFalseOrOrdinaryClockSnapshotCannotClearPendingSave() {
        snapshot(pending = true, blocked = false)
        val initial = RelayWidgetProvider.cloudSyncState(context)
        snapshot(pending = false, blocked = false)
        snapshot()
        val current = RelayWidgetProvider.cloudSyncState(context)
        assertTrue(current.pending)
        assertEquals(initial.generation, current.generation)
        assertTrue(RelayWidgetProvider.completeCloudSync(context, source, current.generation, false, false))
        assertFalse(RelayWidgetProvider.cloudSyncState(context).pending)
    }

    @Test
    fun networkCompletionCannotClearANewerWidgetSave() {
        snapshot(pending = true)
        val started = RelayWidgetProvider.cloudSyncState(context)
        snapshot(pending = true)
        val newer = RelayWidgetProvider.cloudSyncState(context)
        assertTrue(newer.generation > started.generation)
        assertFalse(RelayWidgetProvider.completeCloudSync(context, source, started.generation, false, false))
        assertEquals(newer, RelayWidgetProvider.cloudSyncState(context))
    }

    @Test
    fun oldAccountCompletionCannotChangeAnotherAccountFlags() {
        snapshot(pending = true)
        val started = RelayWidgetProvider.cloudSyncState(context)
        snapshot(owner = "cloud:parent-two", pending = true)
        val current = RelayWidgetProvider.cloudSyncState(context)
        assertFalse(RelayWidgetProvider.completeCloudSync(context, source, started.generation, false, false))
        assertEquals(current, RelayWidgetProvider.cloudSyncState(context))
    }

    @Test
    fun logoutAndSameAccountReentryCannotReuseAnOldGeneration() {
        snapshot(pending = true)
        val started = RelayWidgetProvider.cloudSyncState(context)
        RelayWidgetProvider.clear(context)
        snapshot(pending = true)
        val current = RelayWidgetProvider.cloudSyncState(context)
        assertTrue(current.generation > started.generation)
        assertFalse(RelayWidgetProvider.completeCloudSync(context, source, started.generation, false, false))
        assertTrue(RelayWidgetProvider.cloudSyncState(context).pending)
    }

    @Test
    fun blockedSyncRetainsPendingAndOffersReviewWithoutReplacingTimer() {
        snapshot(pending = true)
        val started = RelayWidgetProvider.cloudSyncState(context)
        assertTrue(RelayWidgetProvider.completeCloudSync(context, source, started.generation, true, true))
        assertEquals("idle", prefs.getString("status", null))
        assertEquals("Saved on this device. Open Relay to review sync.", prefs.getString("message", null))
        assertTrue(RelayWidgetProvider.cloudSyncState(context).pending)
        assertTrue(RelayWidgetProvider.cloudSyncState(context).blocked)
    }

    @Test
    fun networkCompletionDoesNotAcknowledgeANewerWidgetTap() {
        snapshot(pending = true)
        val started = RelayWidgetProvider.cloudSyncState(context)
        assertTrue(RelayWidgetProvider.markPending(context, source, "newer-tap"))
        assertTrue(RelayWidgetProvider.completeCloudSync(context, source, started.generation, false, false))
        assertEquals("newer-tap", prefs.getString("pendingRequestId", null))
        assertEquals("", prefs.getString("message", null))
    }

    @Test
    fun exhaustedTransientSyncKeepsPendingForNextForegroundAttempt() {
        snapshot(pending = true)
        val started = RelayWidgetProvider.cloudSyncState(context)
        assertTrue(RelayWidgetProvider.completeCloudSync(context, source, started.generation, true, false, true))
        assertTrue(RelayWidgetProvider.cloudSyncState(context).pending)
        assertFalse(RelayWidgetProvider.cloudSyncState(context).blocked)
        assertEquals("Saved on this device. Open Relay to finish syncing.", prefs.getString("message", null))
    }

    @Test
    fun successfulBackgroundSyncClearsTheWidgetLocalSaveNotice() {
        snapshot(pending = true)
        val started = RelayWidgetProvider.cloudSyncState(context)
        RelayWidgetProvider.reportResult(context, source, "Saved on this device. Waiting to sync.")
        assertTrue(RelayWidgetProvider.completeCloudSync(context, source, started.generation, true, false))
        assertEquals("Saved on this device. Waiting to sync.", prefs.getString("message", null))
        assertTrue(RelayWidgetProvider.completeCloudSync(context, source, started.generation, false, false))
        assertEquals("", prefs.getString("message", null))
    }

    @Test
    fun successfulBackgroundSyncPreservesAnUnrelatedReminderError() {
        snapshot(pending = true)
        val started = RelayWidgetProvider.cloudSyncState(context)
        val message = "Saved on this device. Open Relay to check syncing and shift reminders."
        RelayWidgetProvider.reportResult(context, source, message)
        assertTrue(RelayWidgetProvider.completeCloudSync(context, source, started.generation, false, false))
        assertEquals(message, prefs.getString("message", null))
    }
}

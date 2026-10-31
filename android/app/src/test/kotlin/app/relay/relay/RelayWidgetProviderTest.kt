package app.relay.relay

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.widget.Chronometer
import android.widget.FrameLayout
import android.widget.RemoteViews
import android.widget.TextView
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.math.abs

/** Inflate and apply the real RemoteViews, including its actions, on Android 16. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class RelayWidgetProviderTest {
    private lateinit var context: Application
    private val source = "cloud:parent-one"
    private val started = "2026-10-31T15:00:00.000Z"

    @Before
    fun setup() {
        context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE).edit().clear().commit()
    }

    private fun snapshot(status: String = "idle", count: Int = 2) {
        RelayWidgetProvider.updateSnapshot(context, mapOf(
            "context" to source,
            "status" to status,
            "childNames" to List(count) { "Child ${it + 1}" },
            "elapsedSeconds" to 300,
            "running" to (status == "work" || status == "baby"),
            "sessionStart" to if (status == "idle") null else started,
            "subtitle" to if (status == "baby") "Child 2" else "Actual work time",
        ))
    }

    private fun render(): View {
        val method = RelayWidgetProvider.Companion.javaClass.getDeclaredMethod("views", Context::class.java, Int::class.javaPrimitiveType)
        method.isAccessible = true
        val views = method.invoke(RelayWidgetProvider.Companion, context, 42) as RemoteViews
        return views.apply(context, FrameLayout(context)).also {
            it.measure(View.MeasureSpec.makeMeasureSpec(350, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(300, View.MeasureSpec.EXACTLY))
            it.layout(0, 0, 350, 300)
        }
    }

    private fun text(root: View, id: Int) = root.findViewById<TextView>(id).text.toString()
    private fun visibility(root: View, id: Int) = root.findViewById<View>(id).visibility
    private fun pick(action: String) {
        RelayWidgetProvider().onReceive(context, Intent("app.relay.relay.widget.$action"))
    }
    private fun click(root: View, id: Int): Intent {
        assertTrue(root.findViewById<View>(id).performClick())
        return requireNotNull(shadowOf(context).nextStartedActivity)
    }

    @Test
    fun unconfiguredWidgetInflatesAndOffersSetup() {
        val root = render()
        assertEquals("Ready when you are", text(root, R.id.widget_status))
        assertEquals("Work Time", text(root, R.id.widget_work))
        assertEquals("Baby Time", text(root, R.id.widget_baby))
        assertEquals(View.GONE, visibility(root, R.id.widget_session_actions))
        assertEquals(MainActivity::class.java.name, click(root, R.id.widget_work).component?.className)
    }

    @Test
    fun idleWorkClickHasOneUseCapabilityAndExpectedIdleState() {
        snapshot()
        val root = render()
        assertEquals("Choose your time", text(root, R.id.widget_status))
        val intent = click(root, R.id.widget_work)
        val replay = Intent(intent)
        val action = requireNotNull(RelayWidgetProvider.consumeAction(context, intent))
        assertEquals("work", action["action"])
        assertEquals(source, action["context"])
        assertEquals("idle", action["expectedStatus"])
        assertNull(action["sessionStart"])
        assertNotNull(action["requestId"])
        assertNull(RelayWidgetProvider.consumeAction(context, replay))
    }

    @Test
    fun workTimerRunsAndInterruptionClickPreservesSessionGuard() {
        snapshot("work")
        val root = render()
        assertEquals("Work Time", text(root, R.id.widget_status))
        assertEquals(View.VISIBLE, visibility(root, R.id.widget_clock))
        assertEquals(View.GONE, visibility(root, R.id.widget_time_static))
        val elapsed = SystemClock.elapsedRealtime() - root.findViewById<Chronometer>(R.id.widget_clock).base
        assertTrue(abs(elapsed - 300000) < 2000)
        assertEquals("Interruption", text(root, R.id.widget_interruption))
        val action = requireNotNull(RelayWidgetProvider.consumeAction(context, click(root, R.id.widget_interruption)))
        assertEquals("interruption", action["action"])
        assertEquals("work", action["expectedStatus"])
        assertEquals(started, action["sessionStart"])
    }

    @Test
    fun interruptedTimerFreezesAndOffersResume() {
        snapshot("interrupted")
        val root = render()
        assertEquals("Interrupted", text(root, R.id.widget_status))
        assertEquals(View.GONE, visibility(root, R.id.widget_clock))
        assertEquals(View.VISIBLE, visibility(root, R.id.widget_time_static))
        assertEquals("00:05:00", text(root, R.id.widget_time_static))
        assertEquals("Resume work", text(root, R.id.widget_interruption))
        val action = requireNotNull(RelayWidgetProvider.consumeAction(context, click(root, R.id.widget_end)))
        assertEquals("end", action["action"])
        assertEquals("interrupted", action["expectedStatus"])
    }

    @Test
    fun babyTimeShowsSelectedBabyWithoutInterruptionControl() {
        snapshot("baby")
        val root = render()
        assertEquals("Baby Time", text(root, R.id.widget_status))
        assertEquals("Child 2", text(root, R.id.widget_subtitle))
        assertEquals(View.GONE, visibility(root, R.id.widget_interruption))
        assertEquals(View.VISIBLE, visibility(root, R.id.widget_session_actions))
    }

    @Test
    fun childPickerRendersOneThroughEightChildrenAndAllBabies() {
        val ids = listOf(R.id.widget_baby_0, R.id.widget_baby_1, R.id.widget_baby_2, R.id.widget_baby_3)
        for (count in 1..8) {
            snapshot(count = count)
            pick("PICK_BABY")
            var root = render()
            assertEquals(View.VISIBLE, visibility(root, R.id.widget_picker))
            assertEquals(View.GONE, visibility(root, R.id.widget_normal))
            for (index in 0 until minOf(count, 4)) assertEquals("Child ${index + 1}", text(root, ids[index]))
            assertEquals(if (count > 1) View.VISIBLE else View.GONE, visibility(root, R.id.widget_all_babies))
            assertEquals("All babies", text(root, R.id.widget_all_babies))
            assertEquals(if (count > 4) View.VISIBLE else View.GONE, visibility(root, R.id.widget_more_babies))
            if (count > 4) {
                pick("PICK_NEXT")
                root = render()
                for (index in 4 until count) assertEquals("Child ${index + 1}", text(root, ids[index - 4]))
                assertEquals("← Back", text(root, R.id.widget_more_babies))
            }
            pick("PICK_CANCEL")
            assertEquals(View.GONE, visibility(render(), R.id.widget_picker))
        }
    }

    @Test
    fun eighthChildAndAllBabiesProduceCorrectSelection() {
        snapshot(count = 8)
        pick("PICK_BABY")
        pick("PICK_NEXT")
        val last = requireNotNull(RelayWidgetProvider.consumeAction(context, click(render(), R.id.widget_baby_3)))
        assertEquals("baby", last["action"])
        assertEquals(7, last["babyIndex"])
        val all = requireNotNull(RelayWidgetProvider.consumeAction(context, click(render(), R.id.widget_all_babies)))
        assertEquals("baby", all["action"])
        assertEquals(-1, all["babyIndex"])
    }

    @Test
    fun forgedIntentCannotInventActionOrAccount() {
        snapshot()
        val forged = Intent("app.relay.relay.widget.TRACK").putExtra("widgetToken", "invented")
        assertNull(RelayWidgetProvider.consumeAction(context, forged))
        val real = click(render(), R.id.widget_work)
        real.putExtra("widgetAction", "end").putExtra("widgetContext", "cloud:other-parent").putExtra("babyIndex", 7)
        val action = requireNotNull(RelayWidgetProvider.consumeAction(context, real))
        assertEquals("work", action["action"])
        assertEquals(source, action["context"])
        assertEquals(-1, action["babyIndex"])
    }

    @Test
    fun snapshotChangeSignOutAndDeletionInvalidateOutstandingActions() {
        snapshot()
        var pending = click(render(), R.id.widget_work)
        snapshot("work")
        assertNull(RelayWidgetProvider.consumeAction(context, pending))
        pending = click(render(), R.id.widget_end)
        RelayWidgetProvider.clear(context)
        assertNull(RelayWidgetProvider.consumeAction(context, pending))
        snapshot()
        pending = click(render(), R.id.widget_work)
        RelayWidgetProvider().onDeleted(context, intArrayOf(42))
        assertNull(RelayWidgetProvider.consumeAction(context, pending))
    }
}

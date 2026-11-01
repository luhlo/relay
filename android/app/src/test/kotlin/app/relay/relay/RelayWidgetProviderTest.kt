package app.relay.relay

import android.app.Application
import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.Context
import android.content.Intent
import android.appwidget.AppWidgetManager
import android.os.Bundle
import android.view.ViewGroup
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

    private fun render(width: Int = 350, height: Int = 300): View {
        val method = RelayWidgetProvider.Companion.javaClass.getDeclaredMethod("viewsForSize", Context::class.java, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
        method.isAccessible = true
        val views = method.invoke(RelayWidgetProvider.Companion, context, 42, width, height) as RemoteViews
        return apply(views, width, height)
    }

    private fun apply(views: RemoteViews, width: Int, height: Int): View =
        views.apply(context, FrameLayout(context)).also {
            it.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            it.layout(0, 0, width, height)
        }

    private fun assertFits(view: View) {
        if (view.visibility != View.VISIBLE) return
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                val child = view.getChildAt(index)
                if (child.visibility != View.VISIBLE) continue
                assertTrue("View ${child.id} overflows right: ${child.right} > ${view.width}", child.right <= view.width)
                assertTrue("View ${child.id} overflows bottom: ${child.bottom} > ${view.height}", child.bottom <= view.height)
                assertTrue(child.left >= 0 && child.top >= 0)
                assertFits(child)
            }
        }
    }

    private fun text(root: View, id: Int) = root.findViewById<TextView>(id).text.toString()
    private fun visibility(root: View, id: Int) = root.findViewById<View>(id).visibility
    private fun pick(action: String) {
        RelayWidgetProvider().onReceive(context, Intent("app.relay.relay.widget.$action"))
    }
    private fun click(root: View, id: Int): Intent {
        assertTrue(root.findViewById<View>(id).performClick())
        assertNull("Widget tracking must not open an activity", shadowOf(context).nextStartedActivity)
        return requireNotNull(shadowOf(context).broadcastIntents.lastOrNull())
    }

    @Test
    fun unconfiguredWidgetInflatesAndOffersSetup() {
        val root = render()
        assertEquals(View.GONE, visibility(root, R.id.widget_session_summary))
        assertEquals("Work Time", text(root, R.id.widget_work))
        assertEquals("Baby Time", text(root, R.id.widget_baby))
        assertEquals(View.GONE, visibility(root, R.id.widget_session_actions))
        assertTrue(root.findViewById<View>(R.id.widget_work).performClick())
        assertEquals(MainActivity::class.java.name, shadowOf(context).nextStartedActivity?.component?.className)
    }

    @Test
    fun idleWorkClickHasOneUseCapabilityAndExpectedIdleState() {
        snapshot()
        val root = render()
        assertEquals(View.GONE, visibility(root, R.id.widget_session_summary))
        assertEquals(View.VISIBLE, visibility(root, R.id.widget_start_actions))
        val intent = click(root, R.id.widget_work)
        val replay = Intent(intent)
        val action = requireNotNull(RelayWidgetProvider.consumeAction(context, intent))
        assertEquals("work", action["action"])
        assertEquals(RelayWidgetActionReceiver::class.java.name, intent.component?.className)
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
        assertEquals("Resume", text(root, R.id.widget_interruption))
        val action = requireNotNull(RelayWidgetProvider.consumeAction(context, click(root, R.id.widget_end)))
        assertEquals("end", action["action"])
        assertEquals("interrupted", action["expectedStatus"])
    }

    @Test
    fun babyTimeShowsSelectedBabyWithoutInterruptionControl() {
        snapshot("baby")
        val root = render()
        assertEquals("Child 2", text(root, R.id.widget_status))
        assertEquals(View.VISIBLE, visibility(root, R.id.widget_change_baby))
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
                pick("PICK_FULL_NEXT")
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
        pick("PICK_FULL_NEXT")
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

    @Test
    fun minimumOneRowAndExpandedSizesKeepAllControlsInsideWidget() {
        for ((width, height) in listOf(110 to 56, 140 to 60, 300 to 60, 160 to 250, 350 to 300)) {
            for (mode in listOf("idle", "work", "interrupted", "baby")) {
                snapshot(mode, count = 8)
                val root = render(width, height)
                assertFits(root)
                if (mode == "idle") {
                    assertTrue(root.findViewById<View>(R.id.widget_work).height >= 36)
                    assertTrue(root.findViewById<View>(R.id.widget_baby).height >= 36)
                } else {
                    assertEquals(View.GONE, visibility(root, R.id.widget_start_actions))
                    assertTrue(root.findViewById<View>(R.id.widget_end).height >= 36)
                }
                pick("PICK_BABY")
                assertFits(render(width, height))
            }
        }
    }

    @Test
    fun compactCarouselIncludesEveryChildAndAllBabiesWithNoActivityLaunch() {
        for (count in 1..8) {
            snapshot(count = count)
            pick("PICK_BABY")
            for (index in 0 until count) {
                val root = render(140, 60)
                assertEquals("Child ${index + 1}", text(root, R.id.widget_selected_baby))
                val action = requireNotNull(RelayWidgetProvider.consumeAction(context, click(root, R.id.widget_selected_baby)))
                assertEquals(index, action["babyIndex"])
                assertFits(root)
                if (count > 1) pick("PICK_NEXT")
            }
            if (count > 1) {
                val root = render(140, 60)
                assertEquals("All babies", text(root, R.id.widget_selected_baby))
                val all = requireNotNull(RelayWidgetProvider.consumeAction(context, click(root, R.id.widget_selected_baby)))
                assertEquals(-1, all["babyIndex"])
                pick("PICK_NEXT")
                assertEquals("Child 1", text(render(140, 60), R.id.widget_selected_baby))
                pick("PICK_PREVIOUS")
                assertEquals("All babies", text(render(140, 60), R.id.widget_selected_baby))
            }
            pick("PICK_CANCEL")
            assertEquals(View.VISIBLE, visibility(render(140, 60), R.id.widget_start_actions))
        }
    }

    @Test
    fun resizeOptionsProducePortraitAndLandscapeLayouts() {
        snapshot("work")
        val options = Bundle().apply {
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 140)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 300)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 60)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 112)
        }
        val manager = AppWidgetManager.getInstance(context)
        val widgetId = shadowOf(manager).createWidget(RelayWidgetProvider::class.java, R.layout.relay_widget)
        manager.updateAppWidgetOptions(widgetId, options)
        RelayWidgetProvider().onAppWidgetOptionsChanged(context, manager, widgetId, options)
        val method = RelayWidgetProvider.Companion.javaClass.getDeclaredMethod("views", Context::class.java, Int::class.javaPrimitiveType)
        method.isAccessible = true
        RuntimeEnvironment.setQualifiers("port")
        var views = method.invoke(RelayWidgetProvider.Companion, context, widgetId) as RemoteViews
        var root = apply(views, 140, 112)
        assertFits(root)
        assertEquals(View.GONE, visibility(root, R.id.widget_status))
        RuntimeEnvironment.setQualifiers("land")
        views = method.invoke(RelayWidgetProvider.Companion, context, widgetId) as RemoteViews
        root = apply(views, 300, 60)
        assertFits(root)
        assertEquals(View.VISIBLE, visibility(root, R.id.widget_status))
    }

    @Test
    fun backgroundResultDisplaysErrorsOnlyForTheCurrentAccount() {
        snapshot("work")
        RelayWidgetProvider.reportResult(context, "cloud:someone-else", "Wrong account")
        assertEquals("Work Time", text(render(), R.id.widget_status))
        RelayWidgetProvider.reportResult(context, source, "Reconnect to save")
        assertEquals("Reconnect to save", text(render(), R.id.widget_status))
        assertEquals("!", text(render(140, 60), R.id.widget_status))
        assertEquals(View.VISIBLE, visibility(render(140, 60), R.id.widget_clock))
        RelayWidgetProvider.reportResult(context, source, null)
        assertEquals("Work Time", text(render(), R.id.widget_status))
    }

    @Test
    fun launcherOffersSeparateFourAndTwoColumnWidgetProviders() {
        val androidNamespace = "http://schemas.android.com/apk/res/android"
        for ((provider, columns) in listOf(RelayWidgetProvider::class.java to 4, RelayCompactWidgetProvider::class.java to 2)) {
            val info = context.packageManager.getReceiverInfo(ComponentName(context, provider), PackageManager.GET_META_DATA)
            assertFalse(info.exported)
            assertEquals("Relay $columns × 1", info.loadLabel(context.packageManager).toString())
            val xml = info.loadXmlMetaData(context.packageManager, "android.appwidget.provider")
            while (xml.next() != org.xmlpull.v1.XmlPullParser.START_TAG) { }
            assertEquals("appwidget-provider", xml.name)
            assertEquals(columns, xml.getAttributeIntValue(androidNamespace, "targetCellWidth", 0))
            assertEquals(1, xml.getAttributeIntValue(androidNamespace, "targetCellHeight", 0))
            assertEquals("110.0dip", xml.getAttributeValue(androidNamespace, "minResizeWidth"))
            assertEquals("56.0dip", xml.getAttributeValue(androidNamespace, "minResizeHeight"))
            xml.close()
        }
        assertTrue(RelayWidgetProvider::class.java.isAssignableFrom(RelayCompactWidgetProvider::class.java))
    }
}

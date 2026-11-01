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
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.Color
import android.view.Gravity
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
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

    private fun snapshot(status: String = "idle", count: Int = 2, colors: Map<String, Any?>? = null, sourceId: String = source, elapsedSeconds: Int = 300, timerLabel: String? = null, subtitle: String? = null) {
        val state = mutableMapOf<String, Any?>(
            "context" to sourceId,
            "status" to status,
            "childNames" to List(count) { "Child ${it + 1}" },
            "elapsedSeconds" to elapsedSeconds,
            "running" to (status != "idle"),
            "sessionStart" to if (status == "idle") null else started,
            "subtitle" to (subtitle ?: if (status == "baby") "Child 2" else if (status == "interrupted") "Interruption time" else "Actual work time"),
        )
        if (timerLabel != null) state["timerLabel"] = timerLabel
        if (colors != null) state["colors"] = colors
        RelayWidgetProvider.updateSnapshot(context, state)
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

    private fun backgroundColor(root: View, id: Int): Int = when (val background = root.findViewById<View>(id).background) {
        is ColorDrawable -> background.color
        is GradientDrawable -> requireNotNull(background.color).defaultColor
        else -> error("Expected a flat background")
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
        assertEquals("Work time", root.findViewById<View>(R.id.widget_session_summary).contentDescription.toString())
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
    fun interruptionStopwatchRunsAndResumeHasADifferentColor() {
        snapshot("interrupted", elapsedSeconds = 35)
        val root = render()
        assertEquals("Interruption time", root.findViewById<View>(R.id.widget_session_summary).contentDescription.toString())
        assertEquals(View.VISIBLE, visibility(root, R.id.widget_clock))
        assertEquals(View.GONE, visibility(root, R.id.widget_time_static))
        val clock = root.findViewById<Chronometer>(R.id.widget_clock)
        assertTrue(abs(SystemClock.elapsedRealtime() - clock.base - 35000) < 2000)
        SystemClock.sleep(2000)
        assertTrue(abs(SystemClock.elapsedRealtime() - clock.base - 37000) < 2000)
        assertEquals("Resume", text(root, R.id.widget_interruption))
        assertEquals(0xFFEEEBFC.toInt(), backgroundColor(root, R.id.widget_session_summary))
        assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertNotEquals(backgroundColor(root, R.id.widget_session_summary), backgroundColor(root, R.id.widget_interruption))
        val action = requireNotNull(RelayWidgetProvider.consumeAction(context, click(root, R.id.widget_end)))
        assertEquals("end", action["action"])
        assertEquals("interrupted", action["expectedStatus"])
    }

    @Test
    fun babyTimeShowsSelectedBabyWithoutInterruptionControl() {
        snapshot("baby")
        val root = render()
        assertEquals("Child 2 time", root.findViewById<View>(R.id.widget_session_summary).contentDescription.toString())
        assertEquals(View.VISIBLE, visibility(root, R.id.widget_change_baby))
        assertEquals(View.GONE, visibility(root, R.id.widget_interruption))
        assertEquals(View.VISIBLE, visibility(root, R.id.widget_session_actions))
    }

    @Test
    fun childPickerShowsDirectNamesForOneToThreeAndCarouselForLargerFamilies() {
        val ids = listOf(R.id.widget_baby_0, R.id.widget_baby_1, R.id.widget_baby_2)
        for (count in 1..8) {
            snapshot(count = count)
            pick("PICK_BABY")
            val root = render(376, 82)
            assertEquals(View.VISIBLE, visibility(root, R.id.widget_picker))
            assertEquals(View.GONE, visibility(root, R.id.widget_normal))
            assertFits(root)
            if (count <= 3) {
                assertEquals(View.VISIBLE, visibility(root, R.id.widget_baby_options))
                assertEquals(View.GONE, visibility(root, R.id.widget_picker_carousel))
                for (index in 0 until count) {
                    assertEquals("Child ${index + 1}", text(root, ids[index]))
                    val action = requireNotNull(RelayWidgetProvider.consumeAction(context, click(root, ids[index])))
                    assertEquals(index, action["babyIndex"])
                }
                assertEquals(if (count > 1) View.VISIBLE else View.GONE, visibility(root, R.id.widget_all_babies))
                if (count > 1) {
                    assertEquals("All babies", text(root, R.id.widget_all_babies))
                    val all = requireNotNull(RelayWidgetProvider.consumeAction(context, click(root, R.id.widget_all_babies)))
                    assertEquals(-1, all["babyIndex"])
                }
            } else {
                assertEquals(View.VISIBLE, visibility(root, R.id.widget_picker_carousel))
                assertEquals("Child 1", text(root, R.id.widget_selected_baby))
            }
            pick("PICK_CANCEL")
            assertEquals(View.GONE, visibility(render(), R.id.widget_picker))
        }
    }

    @Test
    fun eighthChildAndAllBabiesProduceCorrectSelection() {
        snapshot(count = 8)
        pick("PICK_BABY")
        repeat(7) { pick("PICK_NEXT") }
        val last = requireNotNull(RelayWidgetProvider.consumeAction(context, click(render(), R.id.widget_selected_baby)))
        assertEquals("baby", last["action"])
        assertEquals(7, last["babyIndex"])
        pick("PICK_NEXT")
        assertEquals("All babies", text(render(), R.id.widget_selected_baby))
        val all = requireNotNull(RelayWidgetProvider.consumeAction(context, click(render(), R.id.widget_selected_baby)))
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
        for ((width, height) in listOf(110 to 56, 140 to 60, 176 to 82, 376 to 82, 300 to 60, 160 to 250, 350 to 300)) {
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
        for (count in 4..8) {
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
        assertEquals(View.GONE, visibility(root, R.id.widget_status))
    }

    @Test
    fun backgroundResultDisplaysErrorsOnlyForTheCurrentAccount() {
        snapshot("work")
        RelayWidgetProvider.reportResult(context, "cloud:someone-else", "Wrong account")
        assertEquals(View.GONE, visibility(render(), R.id.widget_status))
        RelayWidgetProvider.reportResult(context, source, "Reconnect to save")
        assertEquals("Reconnect to save", render().findViewById<View>(R.id.widget_status).contentDescription)
        assertEquals("!", text(render(140, 60), R.id.widget_status))
        assertEquals(View.VISIBLE, visibility(render(140, 60), R.id.widget_clock))
        RelayWidgetProvider.reportResult(context, source, null)
        assertEquals(View.GONE, visibility(render(), R.id.widget_status))
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

    @Test
    fun idleHalvesFillTheBarWithoutBordersGapsOrRoundedButtons() {
        snapshot()
        for ((width, height) in listOf(110 to 56, 176 to 82, 376 to 82)) {
            val root = render(width, height)
            assertEquals(0, root.paddingLeft + root.paddingTop + root.paddingRight + root.paddingBottom)
            val work = root.findViewById<View>(R.id.widget_work)
            val baby = root.findViewById<View>(R.id.widget_baby)
            assertEquals(width / 2, work.width)
            assertEquals(work.width, baby.width)
            assertEquals(0, work.left)
            assertEquals(work.right, baby.left)
            assertEquals(width, baby.right)
            assertEquals(height, work.height)
            assertEquals(height, baby.height)
            for (view in listOf(work, baby)) {
                val background = view.background
                if (background is GradientDrawable) assertTrue(background.cornerRadii?.all { it == 0f } ?: true)
                else assertTrue(background is ColorDrawable)
                assertEquals(0f, view.elevation)
            }
            assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_work))
            assertEquals(0xFFDDEAAD.toInt(), backgroundColor(root, R.id.widget_baby))
        }
    }

    @Test
    fun activeTimerAndVisibleLabelStayAboveTwoEqualFullColorActionRegions() {
        for (mode in listOf("work", "interrupted", "baby")) {
            snapshot(mode)
            for ((width, height) in listOf(176 to 82, 376 to 82)) {
                val root = render(width, height)
                val timer = root.findViewById<TextView>(R.id.widget_clock)
                assertEquals(if (width < 240) 76 else 80, timer.width)
                assertTrue(root.findViewById<TextView>(R.id.widget_timer_label).width > 0)
                assertEquals(Gravity.CENTER, timer.gravity)
                val first = root.findViewById<View>(if (mode == "baby") R.id.widget_change_baby else R.id.widget_interruption)
                val end = root.findViewById<View>(R.id.widget_end)
                assertEquals(first.width, end.width)
                assertEquals(width / 2, first.width)
                assertEquals(first.right, end.left)
                assertEquals(width, end.right)
                assertEquals(height - 20, first.height)
                assertEquals(first.height, end.height)
                assertEquals(View.GONE, visibility(root, R.id.widget_status))
                assertFits(root)
            }
        }
    }

    @Test
    fun oneTwoAndThreeChildrenFillOneThreeAndFourEqualSections() {
        val ids = listOf(R.id.widget_baby_0, R.id.widget_baby_1, R.id.widget_baby_2)
        for (count in 1..3) {
            snapshot(count = count)
            pick("PICK_BABY")
            for ((width, height) in listOf(176 to 82, 376 to 82)) {
                val root = render(width, height)
                val buttons = ids.take(count).map { root.findViewById<View>(it) }.toMutableList()
                if (count > 1) buttons.add(root.findViewById(R.id.widget_all_babies))
                assertEquals(0, buttons.first().left)
                for ((index, button) in buttons.withIndex()) {
                    assertTrue(abs(button.width - width / buttons.size) <= 1)
                    assertEquals(height, button.height)
                    if (index > 0) assertEquals(buttons[index - 1].right, button.left)
                }
                assertEquals(width, buttons.last().right)
                assertFits(root)
            }
        }
    }

    @Test
    fun carouselArrowsAreDoubleWidthOnBothActualPhoneWidgetSizes() {
        snapshot(count = 4)
        pick("PICK_BABY")
        for ((width, height) in listOf(176 to 82, 376 to 82)) {
            val root = render(width, height)
            assertEquals(56, root.findViewById<View>(R.id.widget_previous_baby).width)
            assertEquals(56, root.findViewById<View>(R.id.widget_next_baby).width)
            assertEquals(width - 112, root.findViewById<View>(R.id.widget_selected_baby).width)
            assertFits(root)
        }
        assertFits(render(110, 56))
    }

    @Test
    fun customColorsPersistAcrossSnapshotsAndChooseReadableText() {
        val colors = mapOf<String, Any?>(
            "work" to 0xFFFFEE00,
            "baby" to 0xFF112244,
            "interruption" to 0xFF005500,
            "resume" to 0xFFFFEEDD,
            "end" to 0xFF000000,
        )
        snapshot(colors = colors)
        var root = render()
        assertEquals(0xFFFFEE00.toInt(), backgroundColor(root, R.id.widget_work))
        assertEquals(0xFF24232C.toInt(), root.findViewById<TextView>(R.id.widget_work).currentTextColor)
        assertEquals(0xFF112244.toInt(), backgroundColor(root, R.id.widget_baby))
        assertEquals(Color.WHITE, root.findViewById<TextView>(R.id.widget_baby).currentTextColor)
        snapshot("work") // Legacy/incomplete snapshots must not erase a saved palette.
        root = render()
        assertEquals(0xFF005500.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFF000000.toInt(), backgroundColor(root, R.id.widget_end))
        assertEquals(Color.WHITE, root.findViewById<TextView>(R.id.widget_end).currentTextColor)
        snapshot("interrupted")
        root = render()
        assertEquals(0xFFFFEEDD.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFF24232C.toInt(), root.findViewById<TextView>(R.id.widget_interruption).currentTextColor)
        assertEquals(0xFFEEEBFC.toInt(), backgroundColor(root, R.id.widget_session_summary))
        assertEquals(0xFF24232C.toInt(), root.findViewById<TextView>(R.id.widget_clock).currentTextColor)
        snapshot("baby")
        root = render()
        assertEquals(0xFF112244.toInt(), backgroundColor(root, R.id.widget_change_baby))
        assertEquals(0xFFEEEBFC.toInt(), backgroundColor(root, R.id.widget_session_summary))
        pick("PICK_BABY")
        root = render()
        assertEquals(0xFFDDEAAD.toInt(), backgroundColor(root, R.id.widget_baby_0))
        assertEquals(0xFFEEEBFC.toInt(), backgroundColor(root, R.id.widget_baby_1))
        assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_all_babies))
        snapshot(sourceId = "cloud:different-parent")
        assertEquals(0xFF6450CA.toInt(), backgroundColor(render(), R.id.widget_work))
    }

    @Test
    fun nativePaletteNormalizesOpacityAndRejectsInvalidColors() {
        snapshot(colors = mapOf(
            "work" to 0x00112233,
            "baby" to "invalid",
            "interruption" to -1,
            "resume" to 0xFF000000,
            "end" to 0x1FFFFFFFF,
        ))
        var root = render()
        assertEquals(0xFF112233.toInt(), backgroundColor(root, R.id.widget_work))
        assertEquals(0xFFDDEAAD.toInt(), backgroundColor(root, R.id.widget_baby))
        snapshot("work")
        root = render()
        assertEquals(Color.WHITE, backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFF24232C.toInt(), root.findViewById<TextView>(R.id.widget_interruption).currentTextColor)
        assertEquals(0xFFDDEAAD.toInt(), backgroundColor(root, R.id.widget_end))
        RelayWidgetProvider.clear(context)
        snapshot()
        assertEquals(0xFF6450CA.toInt(), backgroundColor(render(), R.id.widget_work))
    }

    @Test
    fun orangeSettingsPaletteUsesInkForReadableLabels() {
        snapshot(colors = mapOf("work" to 0xFFE49A58))
        val root = render()
        assertEquals(0xFF24232C.toInt(), root.findViewById<TextView>(R.id.widget_work).currentTextColor)
    }

    @Test
    fun timerLabelUsesExplicitChildNameAndFallsBackForOlderSnapshots() {
        for ((mode, subtitle, expected) in listOf(
            Triple("work", "Actual work time", "Work time"),
            Triple("interrupted", "Anything", "Interruption time"),
            Triple("baby", "Baby 1", "Baby 1 time"),
            Triple("baby", "All babies", "All babies time"),
            Triple("baby", "", "Baby time"),
        )) {
            snapshot(mode, subtitle = subtitle)
            assertEquals(expected, text(render(176, 82), R.id.widget_timer_label))
        }
        snapshot("baby", timerLabel = "Avery time", subtitle = "Old label")
        assertEquals("Avery time", text(render(176, 82), R.id.widget_timer_label))
        snapshot("baby", timerLabel = "Baby 1 time")
        assertEquals("Baby 1", text(render(110, 56), R.id.widget_timer_label))
        assertEquals("Baby 1 time", render(110, 56).findViewById<View>(R.id.widget_session_summary).contentDescription)
    }

    @Test
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun longNamesEllipsizeWhileTheWholeTimerFitsAtMinimumAndPhoneSizes() {
        for (scale in listOf(1f, 1.3f)) {
            RuntimeEnvironment.setFontScale(scale)
            snapshot("baby", timerLabel = "Alexandria Penelope Clementine time")
            for ((width, height) in listOf(110 to 56, 136 to 60, 176 to 82, 376 to 82)) {
                val root = render(width, height)
                val label = root.findViewById<TextView>(R.id.widget_timer_label)
                val clock = root.findViewById<Chronometer>(R.id.widget_clock)
                val value = root.findViewById<View>(R.id.widget_timer_value)
                assertTrue("Name must retain visible space", label.width - label.totalPaddingLeft - label.totalPaddingRight >= 30)
                assertTrue("Name and timer may not overlap", label.right <= value.left)
                assertTrue("Full hours/minutes/seconds must fit", clock.paint.measureText("20:00:00") <= clock.width)
                if (width < 240) {
                    assertTrue("A name prefix should survive at width $width scale $scale", label.layout.getEllipsisStart(0) > 0)
                    assertTrue("Long name should ellipsize at width $width scale $scale", label.layout.getEllipsisCount(0) > 0)
                }
                assertFits(root)
            }
        }
        RuntimeEnvironment.setFontScale(1f)
    }

    @Test
    fun everyWidgetSurfaceUsesItsOwnBackgroundAndTextOverride() {
        val roles = listOf("work", "baby", "interruption", "resume", "end", "timer", "allBabies", "navigation", "notice") +
            (0..7).map { "child$it" }
        val backgrounds = roles.mapIndexed { index, role -> role to (0xFF000000L or (0x123456 + index * 0x090703).toLong()) }.toMap()
        val foregrounds = roles.mapIndexed { index, role -> role to (0xFF000000L or (0xEFDAC0 - index * 0x030507).toLong()) }.toMap()
        val colors = backgrounds + mapOf("version" to 2, "text" to foregrounds)
        fun assertStyle(root: View, id: Int, role: String, textOnly: Boolean = false) {
            if (!textOnly) assertEquals("Background for $role", backgrounds.getValue(role).toInt(), backgroundColor(root, id))
            assertEquals("Text for $role", foregrounds.getValue(role).toInt(), root.findViewById<TextView>(id).currentTextColor)
        }
        snapshot(colors = colors)
        var root = render(176, 82)
        assertStyle(root, R.id.widget_work, "work")
        assertStyle(root, R.id.widget_baby, "baby")
        RelayWidgetProvider.reportResult(context, source, "Reconnect")
        assertStyle(render(176, 82), R.id.widget_error, "notice")
        for (mode in listOf("work", "interrupted", "baby")) {
            snapshot(mode)
            RelayWidgetProvider.reportResult(context, source, "Reconnect")
            root = render(176, 82)
            assertEquals(backgrounds.getValue("timer").toInt(), backgroundColor(root, R.id.widget_session_summary))
            for (id in listOf(R.id.widget_clock, R.id.widget_time_static, R.id.widget_timer_label)) assertStyle(root, id, "timer", true)
            assertStyle(root, R.id.widget_status, "notice")
            assertStyle(root, R.id.widget_end, "end")
            assertStyle(root, if (mode == "baby") R.id.widget_change_baby else R.id.widget_interruption,
                if (mode == "baby") "baby" else if (mode == "interrupted") "resume" else "interruption")
        }
        snapshot(count = 3)
        pick("PICK_BABY")
        root = render(376, 82)
        for ((index, id) in listOf(R.id.widget_baby_0, R.id.widget_baby_1, R.id.widget_baby_2).withIndex()) assertStyle(root, id, "child$index")
        assertStyle(root, R.id.widget_all_babies, "allBabies")
        snapshot(count = 8)
        pick("PICK_BABY")
        for (index in 0..8) {
            root = render(176, 82)
            assertStyle(root, R.id.widget_selected_baby, if (index == 8) "allBabies" else "child$index")
            assertStyle(root, R.id.widget_previous_baby, "navigation")
            assertStyle(root, R.id.widget_next_baby, "navigation")
            pick("PICK_NEXT")
        }
    }

    @Test
    fun partialPalettesPreserveOtherRolesAndAutomaticTextRemovesAnOverride() {
        snapshot(colors = mapOf("version" to 2, "work" to 0xFFE49A58,
            "child7" to 0xFF123456, "timer" to 0xFF345678, "text" to mapOf("work" to 0xFFFFFFFF)))
        snapshot()
        assertEquals(Color.WHITE, render().findViewById<TextView>(R.id.widget_work).currentTextColor)
        snapshot(colors = mapOf("version" to 2, "baby" to 0xFF101010, "text" to emptyMap<String, Any>()))
        var root = render()
        assertEquals(0xFFE49A58.toInt(), backgroundColor(root, R.id.widget_work))
        assertEquals(0xFF24232C.toInt(), root.findViewById<TextView>(R.id.widget_work).currentTextColor)
        snapshot("baby", count = 8)
        assertEquals(0xFF345678.toInt(), backgroundColor(render(), R.id.widget_session_summary))
        pick("PICK_BABY")
        repeat(7) { pick("PICK_NEXT") }
        root = render()
        assertEquals(0xFF123456.toInt(), backgroundColor(root, R.id.widget_selected_baby))
        snapshot(sourceId = "cloud:other-parent")
        assertEquals(0xFF6450CA.toInt(), backgroundColor(render(), R.id.widget_work))
    }

    @Test
    fun legacyDefaultPreferencesAndSnapshotsAdoptTheHarmoniousPalette() {
        val legacy = mapOf("work" to 0xFF6450CA, "baby" to 0xFFDDEAAD, "interruption" to 0xFFF3C879,
            "resume" to 0xFF2762B2, "end" to 0xFF6450CA)
        val prefs = context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE)
        prefs.edit().putString("context", source).putString("status", "interrupted").apply {
            for ((role, color) in legacy) putInt("color:$role", color.toInt())
        }.commit()
        var root = render()
        assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFFDDEAAD.toInt(), backgroundColor(root, R.id.widget_end))
        assertEquals(0xFFEEEBFC.toInt(), backgroundColor(root, R.id.widget_session_summary))
        assertEquals(2, prefs.getInt("paletteVersion", 0))
        snapshot("interrupted", colors = legacy)
        root = render()
        assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFFDDEAAD.toInt(), backgroundColor(root, R.id.widget_end))
    }

    @Test
    fun legacyCustomAndIncompletePalettesKeepTheirOriginalColors() {
        val prefs = context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE)
        prefs.edit().putString("context", source).putString("status", "interrupted")
            .putInt("color:work", 0xFFE49A58.toInt()).putInt("color:resume", 0xFF2762B2.toInt())
            .putInt("color:end", 0xFF6450CA.toInt()).commit()
        var root = render()
        assertEquals(0xFF2762B2.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_end))
        snapshot(colors = mapOf("work" to 0xFFE49A58, "baby" to 0xFFDDEAAD,
            "interruption" to 0xFFF3C879, "resume" to 0xFF2762B2, "end" to 0xFF6450CA))
        snapshot("interrupted")
        root = render()
        assertEquals(0xFF2762B2.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_end))
        assertEquals(0xFFEEEBFC.toInt(), backgroundColor(root, R.id.widget_session_summary))
    }

    @Test
    fun unversionedExtendedBackgroundOrTextPreferencesDoNotMigrateLegacyColors() {
        val legacy = mapOf("work" to 0xFF6450CA, "baby" to 0xFFDDEAAD, "interruption" to 0xFFF3C879,
            "resume" to 0xFF2762B2, "end" to 0xFF6450CA)
        val prefs = context.getSharedPreferences("relay.home_widget.v1", Context.MODE_PRIVATE)
        prefs.edit().putString("context", source).putString("status", "interrupted")
            .putInt("color:timer", 0xFF345678.toInt()).apply {
                for ((role, color) in legacy) putInt("color:$role", color.toInt())
            }.commit()
        var root = render()
        assertEquals(0xFF2762B2.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_end))
        assertEquals(0xFF345678.toInt(), backgroundColor(root, R.id.widget_session_summary))
        snapshot("interrupted", colors = legacy + mapOf("timer" to 0xFF345678))
        root = render()
        assertEquals(0xFF2762B2.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_end))
        snapshot("interrupted", colors = legacy + mapOf("text" to mapOf("work" to 0xFFFFFFFF)))
        root = render()
        assertEquals(0xFF2762B2.toInt(), backgroundColor(root, R.id.widget_interruption))
        assertEquals(0xFF6450CA.toInt(), backgroundColor(root, R.id.widget_end))
    }
}

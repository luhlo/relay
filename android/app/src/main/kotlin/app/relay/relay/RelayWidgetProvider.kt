package app.relay.relay

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.max

/** The launcher only displays a snapshot. All tracking writes happen in Flutter. */
open class RelayWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = refreshAll(context)

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) =
        refreshAll(context)

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val prefs = preferences(context)
        val edit = prefs.edit()
        for (id in appWidgetIds) {
            for ((key, value) in prefs.all) {
                if (key.startsWith("slot:$id:")) {
                    edit.remove(key)
                    if (value is String) edit.remove("token:$value")
                }
            }
        }
        edit.commit()
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED, Intent.ACTION_TIME_CHANGED -> refreshAll(context)
            PICK_BABY, PICK_NEXT, PICK_PREVIOUS, PICK_FULL_NEXT, PICK_CANCEL -> {
                // These are explicit, immutable broadcasts to this non-exported receiver.
                val prefs = preferences(context)
                if (prefs.getString("context", "").isNullOrEmpty()) return
                val page = when (intent.action) {
                    PICK_BABY -> 0
                    PICK_FULL_NEXT -> 4
                    PICK_NEXT -> {
                        val count = (JSONArray(prefs.getString("childNames", "[]")).length().coerceAtLeast(1).let { if (it > 1) it + 1 else it })
                        (prefs.getInt("pickerPage", 0) + 1) % count
                    }
                    PICK_PREVIOUS -> {
                        val count = (JSONArray(prefs.getString("childNames", "[]")).length().coerceAtLeast(1).let { if (it > 1) it + 1 else it })
                        (prefs.getInt("pickerPage", 0) + count - 1) % count
                    }
                    else -> -1
                }
                prefs.edit().putInt("pickerPage", page).commit()
                refreshAll(context)
            }
            else -> super.onReceive(context, intent)
        }
    }

    companion object {
        private const val PREFS = "relay.home_widget.v1"
        private const val PICK_BABY = "app.relay.relay.widget.PICK_BABY"
        private const val PICK_NEXT = "app.relay.relay.widget.PICK_NEXT"
        private const val PICK_FULL_NEXT = "app.relay.relay.widget.PICK_FULL_NEXT"
        private const val PICK_PREVIOUS = "app.relay.relay.widget.PICK_PREVIOUS"
        private const val PICK_CANCEL = "app.relay.relay.widget.PICK_CANCEL"
        private const val LAUNCH_ACTION = "app.relay.relay.widget.TRACK"
        private fun preferences(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private val legacyDefaultColors = mapOf(
            "work" to 0xFF6450CA.toInt(),
            "baby" to 0xFFDDEAAD.toInt(),
            "interruption" to 0xFFF3C879.toInt(),
            "resume" to 0xFF2762B2.toInt(),
            "end" to 0xFF6450CA.toInt(),
        )

        private val defaultColors = mapOf(
            "work" to 0xFF6450CA.toInt(),
            "baby" to 0xFFDDEAAD.toInt(),
            "interruption" to 0xFFF3C879.toInt(),
            "resume" to 0xFF6450CA.toInt(),
            "end" to 0xFFDDEAAD.toInt(),
            "timer" to 0xFFEEEBFC.toInt(),
            "allBabies" to 0xFF6450CA.toInt(),
            "navigation" to 0xFFEEEBFC.toInt(),
            "notice" to 0xFFEEEBFC.toInt(),
        ) + (0..7).associate { index ->
            "child$index" to listOf(0xFFDDEAAD.toInt(), 0xFFEEEBFC.toInt(), 0xFFF3C879.toInt())[index % 3]
        }

        private fun opaqueColor(value: Any?, fallback: Int): Int {
            val number = (value as? Number)?.toLong() ?: return fallback
            if (number < Int.MIN_VALUE.toLong() || number > 0xFFFFFFFFL) return fallback
            return ((number and 0x00FFFFFFL) or 0xFF000000L).toInt()
        }

        /** Choose Relay ink or white according to the higher WCAG contrast ratio. */
        private fun foregroundColor(background: Int): Int {
            fun linear(channel: Int): Double {
                val srgb = channel / 255.0
                return if (srgb <= 0.04045) srgb / 12.92 else Math.pow((srgb + 0.055) / 1.055, 2.4)
            }
            val luminance = 0.2126 * linear(Color.red(background)) +
                0.7152 * linear(Color.green(background)) + 0.0722 * linear(Color.blue(background))
            val ink = 0xFF24232C.toInt()
            val inkLuminance = 0.2126 * linear(Color.red(ink)) +
                0.7152 * linear(Color.green(ink)) + 0.0722 * linear(Color.blue(ink))
            val inkContrast = (maxOf(luminance, inkLuminance) + 0.05) /
                (minOf(luminance, inkLuminance) + 0.05)
            val whiteContrast = 1.05 / (luminance + 0.05)
            return if (inkContrast >= whiteContrast) ink else Color.WHITE
        }

        /** Migrate only the original default palette; an existing custom palette is preserved. */
        private fun migratePalette(prefs: SharedPreferences) {
            if (prefs.getInt("paletteVersion", 0) >= 2) return
            val hasExtended = defaultColors.keys.any { it !in legacyDefaultColors && prefs.contains("color:$it") } ||
                prefs.all.keys.any { it.startsWith("text:") }
            val oldDefaults = !hasExtended && legacyDefaultColors.all { (role, color) ->
                prefs.contains("color:$role") && prefs.getInt("color:$role", color) == color
            }
            val edit = prefs.edit()
            for ((role, fallback) in defaultColors) {
                val color = if (oldDefaults) fallback else prefs.getInt("color:$role", fallback)
                edit.putInt("color:$role", color)
            }
            edit.putInt("paletteVersion", 2).commit()
        }

        private fun timerLabel(status: String?, supplied: String?, subtitle: String): String =
            supplied?.trim()?.take(120)?.takeIf { it.isNotEmpty() } ?: when (status) {
                "work" -> "Work time"
                "interrupted" -> "Interruption time"
                "baby" -> subtitle.trim().take(100).let {
                    when {
                        it.isEmpty() -> "Baby time"
                        it.endsWith(" time", ignoreCase = true) -> it
                        else -> "$it time"
                    }
                }
                else -> ""
            }

        @JvmStatic
        fun updateSnapshot(context: Context, snapshot: Map<String, Any?>) {
            val source = snapshot["context"] as? String ?: return
            if (source.isBlank()) { clear(context); return }
            val names = (snapshot["childNames"] as? List<*>)?.take(8)?.mapIndexed { index, name ->
                (name as? String)?.trim()?.take(40)?.ifBlank { "Baby ${index + 1}" } ?: "Baby ${index + 1}"
            }.orEmpty().ifEmpty { listOf("Baby 1") }
            val status = (snapshot["status"] as? String)?.takeIf { it in setOf("idle", "work", "baby", "interrupted") } ?: "idle"
            val prefs = preferences(context)
            migratePalette(prefs)
            val edit = prefs.edit()
            val suppliedColors = snapshot["colors"] as? Map<*, *>
            val sameSource = prefs.getString("context", null) == source
            val legacyDefaults = suppliedColors != null &&
                ((suppliedColors["version"] as? Number)?.toInt() ?: 0) < 2 &&
                !suppliedColors.containsKey("text") &&
                defaultColors.keys.none { it !in legacyDefaultColors && suppliedColors.containsKey(it) } &&
                legacyDefaultColors.all { (role, color) ->
                    suppliedColors[role] is Number && opaqueColor(suppliedColors[role], 0) == color
                }
            val suppliedText = suppliedColors?.get("text") as? Map<*, *>
            for ((role, fallback) in defaultColors) {
                val previous = if (sameSource) prefs.getInt("color:$role", fallback) else fallback
                val color = when {
                    suppliedColors == null -> previous
                    legacyDefaults && role in legacyDefaultColors -> fallback
                    suppliedColors.containsKey(role) -> opaqueColor(suppliedColors[role], fallback)
                    else -> previous
                }
                edit.putInt("color:$role", color)
                if (suppliedColors != null || !sameSource) {
                    val value = suppliedText?.get(role)
                    if (value is Number && value.toLong() in Int.MIN_VALUE.toLong()..0xFFFFFFFFL) {
                        edit.putInt("text:$role", opaqueColor(value, foregroundColor(color)))
                    } else edit.remove("text:$role")
                }
            }
            val subtitle = (snapshot["subtitle"] as? String).orEmpty().take(160)
            // Old launcher click capabilities must not survive an account/snapshot change.
            for (key in prefs.all.keys) if (key.startsWith("token:")) edit.remove(key)
            edit.putString("context", source)
                .putString("status", status)
                .putString("childNames", JSONArray(names).toString())
                .putString("subtitle", subtitle)
                .putString("timerLabel", timerLabel(status, snapshot["timerLabel"] as? String, subtitle))
                .putInt("paletteVersion", 2)
                .putString("sessionStart", snapshot["sessionStart"] as? String)
                .putString("message", (snapshot["message"] as? String).orEmpty().take(160))
                .putLong("elapsedSeconds", max(0L, (snapshot["elapsedSeconds"] as? Number)?.toLong() ?: 0L))
                .putBoolean("running", snapshot["running"] == true)
                .putLong("savedAt", System.currentTimeMillis())
                .putInt("pickerPage", -1)
                .commit()
            refreshAll(context)
            RelayTimerGuard.sync(context, snapshot)
        }

        @JvmStatic
        fun currentContext(context: Context): String? = preferences(context).getString("context", null)

        @JvmStatic
        fun reportResult(context: Context, expectedContext: String, error: String?) {
            if (currentContext(context) != expectedContext) return
            preferences(context).edit().putString("message", error.orEmpty().take(160)).commit()
            refreshAll(context)
        }

        @JvmStatic
        fun showError(context: Context, message: String) {
            preferences(context).edit().putString("message", message.take(160)).commit()
            refreshAll(context)
        }

        @JvmStatic
        fun clear(context: Context) {
            RelayTimerGuard.clear(context)
            preferences(context).edit().clear().commit()
            refreshAll(context)
        }

        /** A one-use capability prevents other apps forging actions on exported MainActivity. */
        @JvmStatic
        @Synchronized
        fun consumeAction(context: Context, intent: Intent?): Map<String, Any?>? {
            if (intent?.action != LAUNCH_ACTION) return null
            val token = intent.getStringExtra("widgetToken") ?: return null
            intent.removeExtra("widgetToken")
            val prefs = preferences(context)
            val encoded = prefs.getString("token:$token", null) ?: return null
            prefs.edit().remove("token:$token").commit()
            return try {
                val data = JSONObject(encoded)
                if (data.getString("context") != prefs.getString("context", "") ||
                    data.getString("action") !in setOf("work", "baby", "interruption", "end")) null
                else mapOf(
                    "action" to data.getString("action"),
                    "babyIndex" to data.getInt("babyIndex"),
                    "context" to data.getString("context"),
                    "requestId" to token,
                    "expectedStatus" to data.getString("expectedStatus"),
                    "sessionStart" to if (data.isNull("sessionStart")) null else data.getString("sessionStart"),
                )
            } catch (_: Exception) { null }
        }

        @JvmStatic
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val providers = listOf(RelayWidgetProvider::class.java, RelayCompactWidgetProvider::class.java)
            for (provider in providers) {
                val ids = manager.getAppWidgetIds(ComponentName(context, provider))
                for (id in ids) manager.updateAppWidget(id, views(context, id))
            }
        }

        private fun openApp(context: Context, id: Int): PendingIntent = PendingIntent.getActivity(
            context, id * 100 + 90,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                data = Uri.parse("relay-widget://open/$id")
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        private fun track(context: Context, id: Int, action: String, babyIndex: Int = -1): PendingIntent {
            val prefs = preferences(context)
            val source = prefs.getString("context", "").orEmpty()
            if (source.isEmpty()) return openApp(context, id)
            val token = UUID.randomUUID().toString()
            val payload = JSONObject().put("action", action).put("babyIndex", babyIndex).put("context", source)
                .put("expectedStatus", prefs.getString("status", "idle"))
                .put("sessionStart", prefs.getString("sessionStart", null) ?: JSONObject.NULL)
            // Keep one capability per visible action/slot rather than growing preferences indefinitely.
            val slot = "slot:$id:$action:$babyIndex"
            val oldToken = prefs.getString(slot, null)
            prefs.edit().apply {
                if (oldToken != null) remove("token:$oldToken")
                putString(slot, token)
                putString("token:$token", payload.toString())
            }.commit()
            return PendingIntent.getBroadcast(
                context, ("$id:$action:$babyIndex").hashCode(),
                Intent(context, RelayWidgetActionReceiver::class.java).apply {
                    this.action = LAUNCH_ACTION
                    data = Uri.parse("relay-widget://track/$id/$action/$babyIndex")
                    putExtra("widgetToken", token)
                    putExtra("widgetAction", action)
                    putExtra("widgetContext", source)
                    putExtra("babyIndex", babyIndex)
                }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun picker(context: Context, id: Int, action: String): PendingIntent = PendingIntent.getBroadcast(
            context, ("$id:$action").hashCode(),
            Intent(context, RelayWidgetProvider::class.java).apply {
                this.action = action
                data = Uri.parse("relay-widget://pick/$id/$action")
            }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        private fun views(context: Context, id: Int): RemoteViews {
            val options = AppWidgetManager.getInstance(context).getAppWidgetOptions(id)
            val minWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 300)
            val maxWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, minWidth)
            val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 56)
            val maxHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, minHeight)
            // Android chooses the proper RemoteViews when the launcher rotates.
            return RemoteViews(
                viewsForSize(context, id, maxWidth, minHeight),
                viewsForSize(context, id, minWidth, maxHeight),
            )
        }

        private fun viewsForSize(context: Context, id: Int, width: Int, height: Int): RemoteViews {
            val prefs = preferences(context)
            migratePalette(prefs)
            val configured = !prefs.getString("context", "").isNullOrEmpty()
            val status = prefs.getString("status", "idle")
            val names = try {
                val raw = JSONArray(prefs.getString("childNames", "[]"))
                List(raw.length().coerceAtMost(8)) { raw.getString(it) }.ifEmpty { listOf("Baby 1") }
            } catch (_: Exception) { listOf("Baby 1") }
            val page = prefs.getInt("pickerPage", -1)
            val choosing = configured && page >= 0
            val colors = defaultColors.mapValues { (name, fallback) -> prefs.getInt("color:$name", fallback) }
            val rv = RemoteViews(context.packageName, R.layout.relay_widget)
            fun textColor(role: String): Int = if (prefs.contains("text:$role")) {
                prefs.getInt("text:$role", Color.WHITE)
            } else foregroundColor(colors.getValue(role))
            fun style(id: Int, role: String) {
                rv.setInt(id, "setBackgroundColor", colors.getValue(role))
                rv.setTextColor(id, textColor(role))
            }
            style(R.id.widget_work, "work")
            style(R.id.widget_baby, "baby")
            style(R.id.widget_end, "end")
            style(R.id.widget_change_baby, "baby")
            style(R.id.widget_interruption, if (status == "interrupted") "resume" else "interruption")
            style(R.id.widget_baby_0, "child0")
            style(R.id.widget_baby_1, "child1")
            style(R.id.widget_baby_2, "child2")
            style(R.id.widget_all_babies, "allBabies")
            style(R.id.widget_previous_baby, "navigation")
            style(R.id.widget_next_baby, "navigation")
            style(R.id.widget_status, "notice")
            style(R.id.widget_error, "notice")
            rv.setInt(R.id.widget_session_summary, "setBackgroundColor", colors.getValue("timer"))
            rv.setTextColor(R.id.widget_clock, textColor("timer"))
            rv.setTextColor(R.id.widget_time_static, textColor("timer"))
            rv.setTextColor(R.id.widget_timer_label, textColor("timer"))
            // Reserve the complete timer independently of a long child name.
            // Very narrow launchers get smaller numerals rather than losing the name.
            val clockDp = when { width < 150 -> 62; width < 240 -> 76; else -> 80 }
            val clockSp = when { width < 150 -> 10f; width < 240 -> 12f; else -> 14f }
            val clockPx = (clockDp * context.resources.displayMetrics.density).toInt()
            for (viewId in intArrayOf(R.id.widget_clock, R.id.widget_time_static)) {
                rv.setInt(viewId, "setWidth", clockPx)
                rv.setTextViewTextSize(viewId, TypedValue.COMPLEX_UNIT_SP, clockSp)
            }
            rv.setTextViewTextSize(R.id.widget_timer_label, TypedValue.COMPLEX_UNIT_SP, if (width < 150) 10f else 11f)
            rv.setViewVisibility(R.id.widget_normal, if (choosing) View.GONE else View.VISIBLE)
            rv.setViewVisibility(R.id.widget_picker, if (choosing) View.VISIBLE else View.GONE)
            if (choosing) {
                val carousel = names.size > 3
                rv.setViewVisibility(R.id.widget_baby_options, if (carousel) View.GONE else View.VISIBLE)
                rv.setViewVisibility(R.id.widget_picker_carousel, if (carousel) View.VISIBLE else View.GONE)
                if (carousel) {
                    val index = page % (names.size + 1)
                    val selectedName = if (index == names.size) "All babies" else names[index]
                    val selectedIndex = if (index == names.size) -1 else index
                    style(R.id.widget_selected_baby, if (selectedIndex < 0) "allBabies" else "child$selectedIndex")
                    rv.setTextViewText(R.id.widget_selected_baby, selectedName)
                    rv.setContentDescription(R.id.widget_selected_baby, "Start Baby Time for $selectedName")
                    rv.setOnClickPendingIntent(R.id.widget_selected_baby, track(context, id, "baby", selectedIndex))
                    // Double the former 28dp arrows when space allows, while preserving
                    // a readable central label when the widget is resized very narrow.
                    val arrowDp = minOf(56, maxOf(24, (width - 48) / 2))
                    val arrowPx = (arrowDp * context.resources.displayMetrics.density).toInt()
                    rv.setInt(R.id.widget_previous_baby, "setWidth", arrowPx)
                    rv.setInt(R.id.widget_next_baby, "setWidth", arrowPx)
                    rv.setOnClickPendingIntent(R.id.widget_previous_baby, picker(context, id, PICK_PREVIOUS))
                    rv.setOnClickPendingIntent(R.id.widget_next_baby, picker(context, id, PICK_NEXT))
                } else {
                    val buttonIds = intArrayOf(R.id.widget_baby_0, R.id.widget_baby_1, R.id.widget_baby_2)
                    buttonIds.forEachIndexed { index, viewId ->
                        rv.setViewVisibility(viewId, if (index < names.size) View.VISIBLE else View.GONE)
                        if (index < names.size) {
                            rv.setTextViewText(viewId, names[index])
                            rv.setContentDescription(viewId, "Start Baby Time for ${names[index]}")
                            rv.setOnClickPendingIntent(viewId, track(context, id, "baby", index))
                        }
                    }
                    rv.setViewVisibility(R.id.widget_all_babies, if (names.size > 1) View.VISIBLE else View.GONE)
                    rv.setOnClickPendingIntent(R.id.widget_all_babies, track(context, id, "baby", -1))
                }
                return rv
            }
            val active = configured && status != "idle"
            val working = status == "work" || status == "interrupted"
            val message = prefs.getString("message", "").orEmpty()
            rv.setViewVisibility(R.id.widget_error, if (!active && message.isNotBlank()) View.VISIBLE else View.GONE)
            rv.setTextViewText(R.id.widget_error, message)
            rv.setContentDescription(R.id.widget_error, message)
            rv.setViewVisibility(R.id.widget_session_summary, if (active) View.VISIBLE else View.GONE)
            rv.setViewVisibility(R.id.widget_start_actions, if (active) View.GONE else View.VISIBLE)
            rv.setViewVisibility(R.id.widget_status, if (message.isNotBlank()) View.VISIBLE else View.GONE)
            rv.setContentDescription(R.id.widget_status, message)
            val label = timerLabel(status, prefs.getString("timerLabel", null), prefs.getString("subtitle", "").orEmpty())
            val visibleLabel = if (width < 150 && label.endsWith(" time", ignoreCase = true)) label.dropLast(5) else label
            rv.setTextViewText(R.id.widget_timer_label, visibleLabel)
            rv.setContentDescription(R.id.widget_session_summary, label)
            val running = active && prefs.getBoolean("running", false)
            val savedElapsed = prefs.getLong("elapsedSeconds", 0)
            val elapsed = savedElapsed + if (running) max(0L, (System.currentTimeMillis() - prefs.getLong("savedAt", System.currentTimeMillis())) / 1000) else 0
            rv.setViewVisibility(R.id.widget_clock, if (running) View.VISIBLE else View.GONE)
            rv.setViewVisibility(R.id.widget_time_static, if (running) View.GONE else View.VISIBLE)
            rv.setChronometer(R.id.widget_clock, SystemClock.elapsedRealtime() - elapsed * 1000, null, running)
            rv.setTextViewText(R.id.widget_time_static, "%02d:%02d:%02d".format(elapsed / 3600, elapsed / 60 % 60, elapsed % 60))
            rv.setOnClickPendingIntent(R.id.widget_work, track(context, id, "work"))
            rv.setOnClickPendingIntent(R.id.widget_baby, if (configured) picker(context, id, PICK_BABY) else openApp(context, id))
            rv.setViewVisibility(R.id.widget_session_actions, if (active) View.VISIBLE else View.GONE)
            rv.setViewVisibility(R.id.widget_interruption, if (working) View.VISIBLE else View.GONE)
            rv.setViewVisibility(R.id.widget_change_baby, if (status == "baby") View.VISIBLE else View.GONE)
            rv.setTextViewText(R.id.widget_interruption, if (status == "interrupted") "Resume" else "Interruption")
            rv.setOnClickPendingIntent(R.id.widget_interruption, track(context, id, "interruption"))
            rv.setOnClickPendingIntent(R.id.widget_end, track(context, id, "end"))
            rv.setOnClickPendingIntent(R.id.widget_change_baby, picker(context, id, PICK_BABY))
            return rv
        }
    }
}

package app.relay.relay

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
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

        @JvmStatic
        fun updateSnapshot(context: Context, snapshot: Map<String, Any?>) {
            val source = snapshot["context"] as? String ?: return
            if (source.isBlank()) { clear(context); return }
            val names = (snapshot["childNames"] as? List<*>)?.take(8)?.mapIndexed { index, name ->
                (name as? String)?.trim()?.take(40)?.ifBlank { "Baby ${index + 1}" } ?: "Baby ${index + 1}"
            }.orEmpty().ifEmpty { listOf("Baby 1") }
            val status = (snapshot["status"] as? String)?.takeIf { it in setOf("idle", "work", "baby", "interrupted") } ?: "idle"
            val prefs = preferences(context)
            val edit = prefs.edit()
            // Old launcher click capabilities must not survive an account/snapshot change.
            for (key in prefs.all.keys) if (key.startsWith("token:")) edit.remove(key)
            edit.putString("context", source)
                .putString("status", status)
                .putString("childNames", JSONArray(names).toString())
                .putString("subtitle", (snapshot["subtitle"] as? String).orEmpty().take(160))
                .putString("sessionStart", snapshot["sessionStart"] as? String)
                .putString("message", (snapshot["message"] as? String).orEmpty().take(160))
                .putLong("elapsedSeconds", max(0L, (snapshot["elapsedSeconds"] as? Number)?.toLong() ?: 0L))
                .putBoolean("running", snapshot["running"] == true)
                .putLong("savedAt", System.currentTimeMillis())
                .putInt("pickerPage", -1)
                .commit()
            refreshAll(context)
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
            val configured = !prefs.getString("context", "").isNullOrEmpty()
            val status = prefs.getString("status", "idle")
            val names = try {
                val raw = JSONArray(prefs.getString("childNames", "[]"))
                List(raw.length().coerceAtMost(8)) { raw.getString(it) }.ifEmpty { listOf("Baby 1") }
            } catch (_: Exception) { listOf("Baby 1") }
            val page = prefs.getInt("pickerPage", -1)
            val choosing = configured && page >= 0
            val compactPicker = height < 220
            val rv = RemoteViews(context.packageName, R.layout.relay_widget)
            rv.setViewVisibility(R.id.widget_normal, if (choosing) View.GONE else View.VISIBLE)
            rv.setViewVisibility(R.id.widget_picker, if (choosing) View.VISIBLE else View.GONE)
            if (choosing) {
                rv.setViewVisibility(R.id.widget_picker_compact, if (compactPicker) View.VISIBLE else View.GONE)
                rv.setViewVisibility(R.id.widget_picker_full, if (compactPicker) View.GONE else View.VISIBLE)
                rv.setOnClickPendingIntent(R.id.widget_cancel, picker(context, id, PICK_CANCEL))
                rv.setOnClickPendingIntent(R.id.widget_cancel_compact, picker(context, id, PICK_CANCEL))
                val choiceCount = if (names.size > 1) names.size + 1 else names.size
                val index = page % choiceCount
                if (compactPicker) {
                    val selectedName = if (index == names.size) "All babies" else names[index]
                    val selectedIndex = if (index == names.size) -1 else index
                    rv.setTextViewText(R.id.widget_selected_baby, selectedName)
                    rv.setContentDescription(R.id.widget_selected_baby, "Start Baby Time for $selectedName")
                    rv.setOnClickPendingIntent(R.id.widget_selected_baby, track(context, id, "baby", selectedIndex))
                    rv.setViewVisibility(R.id.widget_previous_baby, if (names.size > 1) View.VISIBLE else View.GONE)
                    rv.setViewVisibility(R.id.widget_next_baby, if (names.size > 1) View.VISIBLE else View.GONE)
                    rv.setOnClickPendingIntent(R.id.widget_previous_baby, picker(context, id, PICK_PREVIOUS))
                    rv.setOnClickPendingIntent(R.id.widget_next_baby, picker(context, id, PICK_NEXT))
                } else {
                    val first = (index.coerceAtMost(names.lastIndex) / 4) * 4
                    val buttonIds = intArrayOf(R.id.widget_baby_0, R.id.widget_baby_1, R.id.widget_baby_2, R.id.widget_baby_3)
                    buttonIds.forEachIndexed { offset, viewId ->
                        val child = first + offset
                        rv.setViewVisibility(viewId, if (child < names.size) View.VISIBLE else View.INVISIBLE)
                        if (child < names.size) {
                            rv.setTextViewText(viewId, names[child])
                            rv.setOnClickPendingIntent(viewId, track(context, id, "baby", child))
                        }
                    }
                    rv.setViewVisibility(R.id.widget_baby_row_2, if (names.size > first + 2) View.VISIBLE else View.GONE)
                    rv.setViewVisibility(R.id.widget_all_babies, if (names.size > 1) View.VISIBLE else View.GONE)
                    rv.setOnClickPendingIntent(R.id.widget_all_babies, track(context, id, "baby", -1))
                    rv.setViewVisibility(R.id.widget_more_babies, if (names.size > 4) View.VISIBLE else View.GONE)
                    rv.setTextViewText(R.id.widget_more_babies, if (first == 0) "More babies →" else "← Back")
                    rv.setOnClickPendingIntent(R.id.widget_more_babies, picker(context, id, if (first == 0) PICK_FULL_NEXT else PICK_BABY))
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
            rv.setTextViewText(R.id.widget_status, when (status) {
                "work" -> "Work Time"
                "baby" -> prefs.getString("subtitle", "").orEmpty().ifBlank { "Baby Time" }
                "interrupted" -> "Interrupted"
                else -> "Relay"
            })
            rv.setViewVisibility(R.id.widget_status, if (width >= 180 || message.isNotBlank()) View.VISIBLE else View.GONE)
            if (active && message.isNotBlank()) rv.setTextViewText(R.id.widget_status, if (width < 180) "!" else message)
            rv.setContentDescription(R.id.widget_status, if (message.isNotBlank()) message else if (status == "baby") "Baby Time · ${prefs.getString("subtitle", "")}" else "Open Relay")
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

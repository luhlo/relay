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
class RelayWidgetProvider : AppWidgetProvider() {
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
            PICK_BABY, PICK_NEXT, PICK_CANCEL -> {
                // These are explicit, immutable broadcasts to this non-exported receiver.
                val prefs = preferences(context)
                if (prefs.getString("context", "").isNullOrEmpty()) return
                val page = when (intent.action) {
                    PICK_BABY -> 0
                    PICK_NEXT -> if (prefs.getInt("pickerPage", 0) == 0) 1 else 0
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
                .putLong("elapsedSeconds", max(0L, (snapshot["elapsedSeconds"] as? Number)?.toLong() ?: 0L))
                .putBoolean("running", snapshot["running"] == true)
                .putLong("savedAt", System.currentTimeMillis())
                .putInt("pickerPage", -1)
                .commit()
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
            val ids = manager.getAppWidgetIds(ComponentName(context, RelayWidgetProvider::class.java))
            for (id in ids) manager.updateAppWidget(id, views(context, id))
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
            return PendingIntent.getActivity(
                context, ("$id:$action:$babyIndex").hashCode(),
                Intent(context, MainActivity::class.java).apply {
                    this.action = LAUNCH_ACTION
                    data = Uri.parse("relay-widget://track/$id/$action/$babyIndex")
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
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
            val prefs = preferences(context)
            val configured = !prefs.getString("context", "").isNullOrEmpty()
            val status = prefs.getString("status", "idle")
            val names = try {
                val raw = JSONArray(prefs.getString("childNames", "[]"))
                List(raw.length().coerceAtMost(8)) { raw.getString(it) }
            } catch (_: Exception) { listOf("Baby 1") }
            val page = prefs.getInt("pickerPage", -1)
            val choosing = configured && page >= 0
            val rv = RemoteViews(context.packageName, R.layout.relay_widget)
            rv.setOnClickPendingIntent(R.id.widget_brand, openApp(context, id))
            rv.setViewVisibility(R.id.widget_normal, if (choosing) View.GONE else View.VISIBLE)
            rv.setViewVisibility(R.id.widget_picker, if (choosing) View.VISIBLE else View.GONE)
            if (choosing) {
                rv.setOnClickPendingIntent(R.id.widget_cancel, picker(context, id, PICK_CANCEL))
                val buttonIds = intArrayOf(R.id.widget_baby_0, R.id.widget_baby_1, R.id.widget_baby_2, R.id.widget_baby_3)
                buttonIds.forEachIndexed { offset, viewId ->
                    val index = page * 4 + offset
                    rv.setViewVisibility(viewId, if (index < names.size) View.VISIBLE else View.INVISIBLE)
                    if (index < names.size) {
                        rv.setTextViewText(viewId, names[index])
                        rv.setOnClickPendingIntent(viewId, track(context, id, "baby", index))
                    }
                }
                rv.setViewVisibility(R.id.widget_baby_row_2, if (names.size > page * 4 + 2) View.VISIBLE else View.GONE)
                rv.setViewVisibility(R.id.widget_all_babies, if (names.size > 1) View.VISIBLE else View.GONE)
                rv.setOnClickPendingIntent(R.id.widget_all_babies, track(context, id, "baby", -1))
                rv.setViewVisibility(R.id.widget_more_babies, if (names.size > 4) View.VISIBLE else View.GONE)
                rv.setTextViewText(R.id.widget_more_babies, if (page == 0) "More babies →" else "← Back")
                rv.setOnClickPendingIntent(R.id.widget_more_babies, picker(context, id, PICK_NEXT))
                return rv
            }
            rv.setTextViewText(R.id.widget_status, when {
                !configured -> "Ready when you are"
                status == "work" -> "Work Time"
                status == "baby" -> "Baby Time"
                status == "interrupted" -> "Interrupted"
                else -> "Choose your time"
            })
            rv.setTextViewText(R.id.widget_subtitle, if (configured) prefs.getString("subtitle", "") else "Open Relay to set up your widget")
            val running = configured && prefs.getBoolean("running", false) && status != "idle"
            val savedElapsed = prefs.getLong("elapsedSeconds", 0)
            val elapsed = savedElapsed + if (running) max(0L, (System.currentTimeMillis() - prefs.getLong("savedAt", System.currentTimeMillis())) / 1000) else 0
            rv.setViewVisibility(R.id.widget_clock, if (running) View.VISIBLE else View.GONE)
            rv.setViewVisibility(R.id.widget_time_static, if (running) View.GONE else View.VISIBLE)
            rv.setChronometer(R.id.widget_clock, SystemClock.elapsedRealtime() - elapsed * 1000, null, running)
            rv.setTextViewText(R.id.widget_time_static, "%02d:%02d:%02d".format(elapsed / 3600, elapsed / 60 % 60, elapsed % 60))
            rv.setOnClickPendingIntent(R.id.widget_work, track(context, id, "work"))
            rv.setOnClickPendingIntent(R.id.widget_baby, if (configured) picker(context, id, PICK_BABY) else openApp(context, id))
            val active = configured && status != "idle"
            val working = status == "work" || status == "interrupted"
            rv.setViewVisibility(R.id.widget_session_actions, if (active) View.VISIBLE else View.GONE)
            rv.setViewVisibility(R.id.widget_interruption, if (working) View.VISIBLE else View.GONE)
            rv.setTextViewText(R.id.widget_interruption, if (status == "interrupted") "Resume work" else "Interruption")
            rv.setOnClickPendingIntent(R.id.widget_interruption, track(context, id, "interruption"))
            rv.setOnClickPendingIntent(R.id.widget_end, track(context, id, "end"))
            return rv
        }
    }
}

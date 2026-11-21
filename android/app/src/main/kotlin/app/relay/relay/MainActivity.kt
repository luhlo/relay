package app.relay.relay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var widgetChannel: MethodChannel? = null
    private var receiverRegistered = false
    private val updates = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            widgetChannel?.invokeMethod("stateChanged", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        widgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.relay.relay/widget"
        ).also { channel -> channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "context" -> result.success(RelayWidgetProvider.currentContext(this))
                "timerNotificationSettings" -> {
                    RelayWidgetProvider.refreshAll(this)
                    result.success(RelayTimerNotification.settings(this))
                }
                "setTimerNotificationEnabled" -> {
                    val enabled = call.arguments as? Boolean
                    if (enabled == null) result.error("invalid_setting", "A boolean is required", null)
                    else result.success(RelayTimerNotification.setEnabled(this, enabled))
                }
                "update" -> {
                    val snapshot = call.arguments as? Map<*, *>
                    if (snapshot == null) {
                        result.error("invalid_snapshot", "A snapshot is required", null)
                    } else {
                        RelayWidgetProvider.updateSnapshot(
                            this, snapshot.entries.associate { it.key.toString() to it.value }
                        )
                        RelayCloudSyncWorker.enqueueIfNeeded(this)
                        result.success(null)
                    }
                }
                "requestCloudSync" -> {
                    RelayCloudSyncWorker.enqueueIfNeeded(this)
                    result.success(null)
                }
                "clear" -> {
                    RelayWidgetProvider.clear(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } }
        if (!receiverRegistered) {
            ContextCompat.registerReceiver(this, updates,
                IntentFilter("app.relay.relay.widget.STATE_CHANGED"), ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }
    }

    override fun onResume() {
        super.onResume()
        // Permission/channel settings may have changed while Android Settings was open.
        RelayWidgetProvider.refreshAll(this)
    }

    override fun onDestroy() {
        if (receiverRegistered) unregisterReceiver(updates)
        receiverRegistered = false
        widgetChannel?.setMethodCallHandler(null)
        super.onDestroy()
    }
}

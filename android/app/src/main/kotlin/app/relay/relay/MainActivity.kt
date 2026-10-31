package app.relay.relay

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var widgetChannel: MethodChannel? = null
    private var pendingWidgetAction: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        acceptWidgetAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptWidgetAction(intent)
    }

    private fun acceptWidgetAction(intent: Intent?) {
        if (intent == null) return
        val action = RelayWidgetProvider.consumeAction(this, intent) ?: return
        pendingWidgetAction = action
        widgetChannel?.invokeMethod("actionAvailable", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        widgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.relay.relay/widget"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "pendingContext" -> result.success(pendingWidgetAction?.get("context"))
                    "takeAction" -> {
                        val pending = pendingWidgetAction
                        pendingWidgetAction = null
                        result.success(pending)
                    }
                    "update" -> {
                        val snapshot = call.arguments as? Map<*, *>
                        if (snapshot == null) {
                            result.error("invalid_snapshot", "A snapshot is required", null)
                        } else {
                            RelayWidgetProvider.updateSnapshot(
                                this, snapshot.entries.associate { it.key.toString() to it.value }
                            )
                            result.success(null)
                        }
                    }
                    "clear" -> {
                        pendingWidgetAction = null
                        RelayWidgetProvider.clear(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}

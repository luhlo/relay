package app.relay.relay

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.relay.relay/widget"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "context" -> result.success(RelayWidgetProvider.currentContext(this))
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
                    RelayWidgetProvider.clear(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}

package app.relay.relay

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume

/** Runs the same authenticated Dart persistence code as Relay, without a window. */
class RelayWidgetWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val action = try {
            JSONObject(inputData.getString(ACTION_DATA) ?: return Result.success()).asMap()
        } catch (_: Exception) {
            return Result.success()
        }
        val source = action["context"] as? String ?: return Result.success()
        // A queued click must never apply to a different account after sign-out.
        if (currentContext() != source) return Result.success()
        var engine: FlutterEngine? = null
        var channel: MethodChannel? = null
        try {
            val completion = withTimeoutOrNull(60_000L) {
                withContext(Dispatchers.Main.immediate) {
                    val loader = FlutterInjector.instance().flutterLoader()
                    loader.startInitialization(applicationContext)
                    loader.ensureInitializationComplete(applicationContext, null)
                    val workerEngine = FlutterEngine(applicationContext)
                    engine = workerEngine
                    val workerChannel = MethodChannel(
                        workerEngine.dartExecutor.binaryMessenger,
                        "app.relay.relay/widget_background",
                    )
                    channel = workerChannel
                    suspendCancellableCoroutine<Map<String, Any?>> { continuation ->
                        workerChannel.setMethodCallHandler { call, result ->
                            when (call.method) {
                                "getAction" -> result.success(
                                    if (currentContext() == source) action else null,
                                )
                                "complete" -> {
                                    val response = (call.arguments as? Map<*, *>)
                                        ?.entries?.associate { it.key.toString() to it.value }
                                        ?: mapOf("success" to false, "error" to "Could not save. Tap to retry.")
                                    result.success(null)
                                    if (continuation.isActive) continuation.resume(response)
                                }
                                else -> result.notImplemented()
                            }
                        }
                        workerEngine.dartExecutor.executeDartEntrypoint(
                            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "relayWidgetBackground"),
                        )
                    }
                }
            }
            if (currentContext() == source) {
                val snapshot = (completion?.get("snapshot") as? Map<*, *>)
                    ?.entries?.associate { it.key.toString() to it.value }
                if (snapshot?.get("context") == source) {
                    RelayWidgetProvider.updateSnapshot(applicationContext, snapshot)
                }
                val error = if (completion?.get("success") == true) completion["error"] as? String
                    else (completion?.get("error") as? String)
                        ?: "Save unconfirmed. Open Relay to refresh."
                RelayWidgetProvider.reportResult(applicationContext, source, error)
            }
        } catch (cancelled: CancellationException) {
            // WorkManager may restart the same request; Dart's request ID guard makes it idempotent.
            throw cancelled
        } catch (_: Exception) {
            if (currentContext() == source) {
                RelayWidgetProvider.reportResult(
                    applicationContext, source, "Could not save. Open Relay to refresh.",
                )
            }
        } finally {
            withContext(NonCancellable + Dispatchers.Main.immediate) {
                channel?.setMethodCallHandler(null)
                engine?.destroy()
            }
        }
        // Never blindly retry a cloud mutation whose acknowledgement may have been lost.
        return Result.success()
    }

    private fun currentContext(): String =
        RelayWidgetProvider.currentContext(applicationContext).orEmpty()

    companion object {
        const val ACTION_DATA = "relay.widget.action"
        const val QUEUE_NAME = "relay.widget.actions"
    }
}

private fun JSONObject.asMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
    when (val value = get(key)) {
        JSONObject.NULL -> null
        is JSONObject -> value.asMap()
        is JSONArray -> (0 until value.length()).map { index ->
            value.get(index).let { if (it == JSONObject.NULL) null else it }
        }
        else -> value
    }
}

package app.relay.relay

import android.content.Context
import android.content.Intent
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
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
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

/** Network-only queue: widget buttons continue saving without connectivity. */
class RelayCloudSyncWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val source = inputData.getString(CONTEXT_DATA) ?: return Result.success()
        val initial = RelayWidgetProvider.cloudSyncState(applicationContext)
        if (!shouldStart(source, initial)) return Result.success()
        var engine: FlutterEngine? = null
        var channel: MethodChannel? = null
        try {
            val completion = withTimeoutOrNull(110_000L) {
                withContext(Dispatchers.Main.immediate) {
                    val loader = FlutterInjector.instance().flutterLoader()
                    loader.startInitialization(applicationContext)
                    loader.ensureInitializationComplete(applicationContext, null)
                    val workerEngine = FlutterEngine(applicationContext)
                    engine = workerEngine
                    val workerChannel = MethodChannel(
                        workerEngine.dartExecutor.binaryMessenger,
                        "app.relay.relay/cloud_sync_background",
                    )
                    channel = workerChannel
                    suspendCancellableCoroutine<Map<String, Any?>> { continuation ->
                        workerChannel.setMethodCallHandler { call, result ->
                            when (call.method) {
                                "getAction" -> result.success(
                                    if (RelayWidgetProvider.currentContext(applicationContext) == source)
                                        mapOf("context" to source) else null,
                                )
                                "complete" -> {
                                    val response = (call.arguments as? Map<*, *>)
                                        ?.entries?.associate { it.key.toString() to it.value }
                                        ?: mapOf("context" to source, "pending" to true, "blocked" to true)
                                    result.success(null)
                                    if (continuation.isActive) continuation.resume(response)
                                }
                                else -> result.notImplemented()
                            }
                        }
                        workerEngine.dartExecutor.executeDartEntrypoint(
                            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "relayCloudSyncBackground"),
                        )
                    }
                }
            }
            if (completion?.get("context") == source) {
                RelayWidgetProvider.completeCloudSync(
                    applicationContext, source, initial.generation,
                    pending = completion["pending"] != false,
                    blocked = completion["blocked"] == true,
                    deferred = completion["pending"] != false && runAttemptCount >= MAX_RETRIES,
                )
            }
            if (RelayWidgetProvider.currentContext(applicationContext) == source) {
                applicationContext.sendBroadcast(Intent("app.relay.relay.widget.STATE_CHANGED")
                    .setPackage(applicationContext.packageName))
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // The durable local outbox remains the source of truth. Never
            // replay a widget action or publish a network result as its snapshot.
        } finally {
            withContext(NonCancellable + Dispatchers.Main.immediate) {
                channel?.setMethodCallHandler(null)
                engine?.destroy()
            }
        }
        val latest = RelayWidgetProvider.cloudSyncState(applicationContext)
        if (shouldStart(source, latest) && runAttemptCount >= MAX_RETRIES) {
            RelayWidgetProvider.completeCloudSync(
                applicationContext, source, initial.generation,
                pending = true, blocked = false, deferred = true,
            )
        }
        return if (shouldStart(source, latest) && runAttemptCount < MAX_RETRIES) Result.retry()
            else Result.success()
    }

    companion object {
        const val CONTEXT_DATA = "relay.cloud.sync.context"
        const val MAX_RETRIES = 8

        internal fun queueName(source: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(source.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            return "relay.cloud.sync.$digest"
        }

        internal fun shouldStart(source: String, state: RelayCloudSyncState): Boolean =
            source.startsWith("cloud:") && source.length > "cloud:".length &&
                state.source == source && state.pending && !state.blocked

        internal fun request(source: String): OneTimeWorkRequest =
            OneTimeWorkRequestBuilder<RelayCloudSyncWorker>()
                .setInputData(Data.Builder().putString(CONTEXT_DATA, source).build())
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()

        @JvmStatic
        fun enqueueIfNeeded(context: Context) {
            val state = RelayWidgetProvider.cloudSyncState(context)
            val source = state.source ?: return
            if (!shouldStart(source, state)) return
            try {
                WorkManager.getInstance(context).enqueueUniqueWork(
                    queueName(source), ExistingWorkPolicy.APPEND_OR_REPLACE, request(source),
                )
            } catch (_: Exception) {
                // An unavailable scheduler cannot invalidate a saved timer.
            }
        }

        @JvmStatic
        fun cancel(context: Context, source: String?) {
            if (source.isNullOrBlank() || !source.startsWith("cloud:")) return
            try {
                WorkManager.getInstance(context).cancelUniqueWork(queueName(source))
            } catch (_: Exception) {
                // Source and generation guards still protect queued workers.
            }
        }
    }
}

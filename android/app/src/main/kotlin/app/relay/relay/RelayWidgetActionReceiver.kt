package app.relay.relay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.OutOfQuotaPolicy
import org.json.JSONObject
import java.util.concurrent.Executor

/** A widget click queues durable work without starting an Activity. */
class RelayWidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = RelayWidgetProvider.consumeAction(context, intent) ?: return
        val source = action["context"] as String
        val requestId = action["requestId"] as String
        if (!RelayWidgetProvider.markPending(context, source, requestId)) return
        val receivedAt = SystemClock.elapsedRealtime()
        Log.d("RelayWidgetTap", "Accepted ${action["action"]}; saving feedback shown")
        val pending = goAsync()
        try {
            val builder = OneTimeWorkRequestBuilder<RelayWidgetWorker>()
                .setInputData(Data.Builder().putString(RelayWidgetWorker.ACTION_DATA, JSONObject(action).toString()).build())
            if (Build.VERSION.SDK_INT >= 31) builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            val work = builder.build()
            val operation = WorkManager.getInstance(context).enqueueUniqueWork(
                RelayWidgetWorker.QUEUE_NAME,
                ExistingWorkPolicy.APPEND_OR_REPLACE,
                work,
            )
            operation.result.addListener({
                try {
                    operation.result.get()
                    Log.d("RelayWidgetTap", "Queued ${action["action"]} in ${SystemClock.elapsedRealtime() - receivedAt}ms")
                } catch (_: Exception) {
                    RelayWidgetProvider.reportResult(
                        context, source, "Could not queue this change. Tap to retry.", requestId,
                    )
                } finally {
                    pending.finish()
                }
            }, Executor { command -> command.run() })
        } catch (_: Exception) {
            RelayWidgetProvider.reportResult(
                context, source, "Could not queue this change. Tap to retry.", requestId,
            )
            pending.finish()
        }
    }
}

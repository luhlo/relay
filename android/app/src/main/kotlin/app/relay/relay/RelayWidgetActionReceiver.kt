package app.relay.relay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import org.json.JSONObject
import java.util.concurrent.Executor

/** A widget click queues durable work without starting an Activity. */
class RelayWidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = RelayWidgetProvider.consumeAction(context, intent) ?: return
        val work = OneTimeWorkRequestBuilder<RelayWidgetWorker>()
            .setInputData(
                Data.Builder()
                    .putString(RelayWidgetWorker.ACTION_DATA, JSONObject(action).toString())
                    .build(),
            )
            .build()
        val pending = goAsync()
        try {
            val operation = WorkManager.getInstance(context).enqueueUniqueWork(
                RelayWidgetWorker.QUEUE_NAME,
                ExistingWorkPolicy.APPEND_OR_REPLACE,
                work,
            )
            operation.result.addListener({
                try {
                    operation.result.get()
                } catch (_: Exception) {
                    RelayWidgetProvider.reportResult(
                        context, action["context"] as String, "Could not queue this change. Tap to retry.",
                    )
                } finally {
                    pending.finish()
                }
            }, Executor { command -> command.run() })
        } catch (_: Exception) {
            RelayWidgetProvider.reportResult(
                context, action["context"] as String, "Could not queue this change. Tap to retry.",
            )
            pending.finish()
        }
    }
}

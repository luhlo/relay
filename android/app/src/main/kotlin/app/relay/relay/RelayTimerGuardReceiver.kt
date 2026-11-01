package app.relay.relay

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import org.json.JSONObject
import java.util.concurrent.Executor

/** Guard alarms and notification buttons never launch an Activity. */
class RelayTimerGuardReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                Intent.ACTION_TIME_CHANGED, AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED)) {
            RelayTimerGuard.restore(context)
            return
        }
        val action = RelayTimerGuard.consumeRequest(context, intent) ?: return
        val pending = goAsync()
        try {
            val request = OneTimeWorkRequestBuilder<RelayWidgetWorker>()
                .setInputData(Data.Builder().putString(RelayWidgetWorker.ACTION_DATA, JSONObject(action).toString()).build())
                .build()
            val operation = WorkManager.getInstance(context).enqueueUniqueWork(
                RelayWidgetWorker.QUEUE_NAME, ExistingWorkPolicy.APPEND_OR_REPLACE, request,
            )
            operation.result.addListener({
                try { operation.result.get() }
                catch (_: Exception) {
                    if (action["action"] == "guard") RelayTimerGuard.retryAfterFailure(context, action["context"] as String)
                    RelayWidgetProvider.reportResult(context, action["context"] as String, "Timer check-in could not run. Open Relay to refresh.")
                }
                finally { pending.finish() }
            }, Executor { it.run() })
        } catch (_: Exception) {
            if (action["action"] == "guard") RelayTimerGuard.retryAfterFailure(context, action["context"] as String)
            RelayWidgetProvider.reportResult(context, action["context"] as String, "Timer check-in could not run. Open Relay to refresh.")
            pending.finish()
        }
    }
}

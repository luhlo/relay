package app.relay.relay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Respect a dismissed Live Update for this session; tracking itself keeps running. */
class RelayTimerNotificationDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        RelayWidgetProvider.dismissTimerNotification(context, intent)
    }
}

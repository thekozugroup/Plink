package app.plink.android.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject

class TaskContinuityCapabilitiesReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TaskContinuityCapabilities.ACTION) return
        resultData = try {
            TaskContinuityCapabilities.report(context).toString()
        } catch (_: Exception) {
            JSONObject().put("error", "diagnostic_failed").toString()
        }
    }
}

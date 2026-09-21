package app.plink.android.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import app.plink.android.PlinkApplication
import app.plink.android.reconnect.ReconnectNetworkResolver
import org.json.JSONArray
import org.json.JSONObject

/** Read-only diagnostics in the app process; the debug manifest restricts callers to DUMP. */
class DebugSessionStateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "app.plink.android.DEBUG_SESSION_STATE") return
        val result = JSONObject()
        try {
            val app = context.applicationContext as PlinkApplication
            val session = app.sessionController
            result.put("sessionStatus", session.status.value.name)
            result.put("reconnectState", session.reconnectState.value.toString())
            result.put("clipboardConnected", session.clipboardConnection() != null)
            result.put("clipboardSyncEnabled", app.featureSettings.clipboardSyncEnabled.value)
            result.put("clipboardState", app.clipboardSync.state.value.message)
            val interfaces = JSONArray()
            for (snapshot in ReconnectNetworkResolver(context).currentInterfaces()) {
                interfaces.put(JSONObject().apply {
                    put("name", snapshot.name)
                    put("index", snapshot.index)
                    put("localIPv4", snapshot.localIPv4)
                    put("prefixLength", snapshot.prefixLength)
                    put("up", snapshot.up)
                    put("loopback", snapshot.loopback)
                    put("pointToPoint", snapshot.pointToPoint)
                    put("broadcast", snapshot.broadcast)
                    put("vpn", snapshot.vpn)
                    put("matchingAndroidNetwork", snapshot.matchingAndroidNetwork)
                })
            }
            result.put("currentInterfaceSnapshots", interfaces)
        } catch (error: Exception) {
            result.put("error", error.javaClass.simpleName)
        }
        resultData = result.toString()
    }
}

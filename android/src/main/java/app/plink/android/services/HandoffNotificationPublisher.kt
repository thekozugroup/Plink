package app.plink.android.services

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import app.plink.android.R
import app.plink.android.continuity.HandoffActionActivity
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

class HandoffNotificationPublisher(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    fun publish(envelope: PlinkEnvelope) {
        check(manager.areNotificationsEnabled()) { "Continuity notifications are disabled." }
        val actionIntent = when (envelope.type) {
            PlinkEventType.WebOpen -> Intent(context, HandoffActionActivity::class.java).apply {
                action = HandoffActionActivity.ACTION_OPEN_URL
                putExtra(HandoffActionActivity.EXTRA_URL, envelope.value("url"))
            }
            PlinkEventType.ClipboardUpdated -> Intent(context, HandoffActionActivity::class.java).apply {
                action = HandoffActionActivity.ACTION_COPY
                putExtra(HandoffActionActivity.EXTRA_TEXT, envelope.value("text"))
            }
            else -> throw IllegalArgumentException("Unsupported handoff.")
        }
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Continuity handoffs", NotificationManager.IMPORTANCE_DEFAULT)
        )
        val pending = PendingIntent.getActivity(
            context,
            envelope.id.hashCode(),
            actionIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val isWeb = envelope.type == PlinkEventType.WebOpen
        manager.notify(
            envelope.id.hashCode(),
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_plink)
                .setContentTitle(if (isWeb) "Open link from Mac" else "Copy text from Mac")
                .setContentText(if (isWeb) envelope.value("url") else "Tap to copy shared text")
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build()
        )
    }

    private fun PlinkEnvelope.value(key: String): String =
        payload[key]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("payload.$key is required.")

    companion object { private const val CHANNEL = "continuity_handoffs" }
}

package app.plink.android.continuity

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import app.plink.android.R
import java.io.InputStream
import java.io.OutputStream

class AndroidFileTransferEnvironment(private val context: Context) : FileTransferEnvironment {
    private val resolver: ContentResolver = context.contentResolver
    private val notifications = context.getSystemService(NotificationManager::class.java)

    override fun openSource(token: String): InputStream =
        resolver.openInputStream(Uri.parse(token)) ?: error("The selected file cannot be opened.")

    override fun openDestination(token: String): OutputStream =
        resolver.openOutputStream(Uri.parse(token), "w") ?: error("The selected destination cannot be opened.")

    override fun showIncomingOffer(handle: String, offer: IncomingFileOffer): Boolean {
        if (!notificationsAvailable()) return false
        ensureChannel()
        if (Build.VERSION.SDK_INT >= 26 && notifications.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE) {
            return false
        }
        val accept = PendingIntent.getActivity(
            context,
            handle.hashCode(),
            Intent(context, FileTransferAcceptanceActivity::class.java).apply {
                action = FileTransferAcceptanceActivity.ACTION_ACCEPT
                putExtra(FileTransferAcceptanceActivity.EXTRA_HANDLE, handle)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val decline = PendingIntent.getActivity(
            context,
            handle.hashCode() xor 0x5f3759df,
            Intent(context, FileTransferAcceptanceActivity::class.java).apply {
                action = FileTransferAcceptanceActivity.ACTION_DECLINE
                putExtra(FileTransferAcceptanceActivity.EXTRA_HANDLE, handle)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return runCatching {
            notifications.notify(
                notificationId(handle),
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_plink)
                    .setContentTitle("File from your Mac")
                    .setContentText("${offer.name} • ${formatBytes(offer.sizeBytes)}")
                    .setContentIntent(accept)
                    .addAction(0, "Choose destination", accept)
                    .addAction(0, "Decline", decline)
                    .setAutoCancel(false)
                    .setOnlyAlertOnce(true)
                    .build()
            )
            true
        }.getOrDefault(false)
    }

    override fun dismissIncomingOffer(handle: String) {
        notifications.cancel(notificationId(handle))
    }

    override fun deleteNewDestination(token: String): Boolean =
        runCatching { resolver.delete(Uri.parse(token), null, null) > 0 }.getOrDefault(false)

    override fun releaseDestination(token: String) {
        runCatching {
            resolver.releasePersistableUriPermission(Uri.parse(token), Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
    }

    private fun notificationsAvailable(): Boolean = notifications.areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED)

    private fun ensureChannel() {
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Incoming file transfers", NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    private fun notificationId(handle: String): Int = handle.hashCode()

    private fun formatBytes(bytes: Long): String = when {
        bytes >= 1024 * 1024 -> "${bytes / (1024 * 1024)} MiB"
        bytes >= 1024 -> "${bytes / 1024} KiB"
        else -> "$bytes bytes"
    }

    companion object { const val CHANNEL_ID = "incoming_file_transfers" }
}

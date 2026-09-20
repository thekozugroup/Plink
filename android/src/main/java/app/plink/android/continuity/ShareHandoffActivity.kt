package app.plink.android.continuity

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import app.plink.android.PlinkApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class ShareHandoffActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent.action) {
            Intent.ACTION_SEND -> if (intent.type == "text/plain" && intent.streamUri() == null) {
                sendSharedText()
                finish()
            } else {
                confirmSharedFile()
            }
            else -> finish()
        }
    }

    private fun sendSharedText() {
        if (intent.type != "text/plain") return showResult("Plink can only share plain text.")
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
        if (text.isEmpty()) return showResult("Nothing to share with Plink.")
        if (text.length > MAX_SHARED_TEXT_LENGTH) return showResult("Shared text is too long for Plink.")
        val shared = runCatching { SharedTextClassifier.classify(text) }.getOrNull()
            ?: return showResult("Plink could not read the shared text.")
        val event = when (shared) {
            is SharedText.Clipboard -> ClipboardUpdatedEvent(shared.text)
            is SharedText.Web -> WebOpenEvent(shared.url)
        }
        val queued = runCatching {
            (applicationContext as PlinkApplication).sessionController.sendEvent(event)
        }.getOrDefault(false)
        showResult(if (queued) "Queued for your Mac." else "Plink is unavailable or this feature is disabled.")
    }

    private fun showResult(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }

    private fun confirmSharedFile() {
        val uri = intent.streamUri()
        if (uri == null || intent.clipData?.itemCount?.let { it > 1 } == true) {
            showResult("Choose one file to share with Plink.")
            finish()
            return
        }
        if (uri.scheme != ContentResolver.SCHEME_CONTENT ||
            intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0) {
            showResult("The source app must grant Plink access to a shared file.")
            finish()
            return
        }
        val metadata = runCatching { fileMetadata(uri) }.getOrNull()
        if (metadata == null) {
            showResult("Plink cannot read this shared file.")
            finish()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("Send file to your Mac?")
            .setMessage(metadata.first)
            .setPositiveButton("Send") { _, _ ->
                scope.launch {
                    val result = runCatching {
                        app().sessionController.offerSharedFile(
                            OutgoingFileSource(uri.toString(), metadata.first, metadata.second)
                        )
                    }.getOrDefault(FileOfferStartResult.Failed)
                    showResult(when (result) {
                        FileOfferStartResult.Offered -> "File offered to your Mac. Waiting for acceptance."
                        FileOfferStartResult.TooLarge -> "Files must be 16 MiB or smaller."
                        FileOfferStartResult.Busy -> "Another file transfer is active."
                        FileOfferStartResult.Disabled -> "Enable Files in Plink before sharing."
                        FileOfferStartResult.Unavailable -> "Pair with your Mac before sharing a file."
                        FileOfferStartResult.Invalid -> "This file name or type cannot be shared."
                        FileOfferStartResult.Failed -> "Plink could not prepare or send this file."
                    })
                    finish()
                }
            }
            .setNegativeButton("Cancel") { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .show()
    }

    private fun fileMetadata(uri: Uri): Pair<String, String> {
        val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            cursor.takeIf(Cursor::moveToFirst)?.let {
                cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { index -> index >= 0 }
                    ?.let(cursor::getString)
            }
        }?.takeIf { it.isNotBlank() } ?: "Shared file"
        val mimeType = intent.type?.takeIf { it.isNotBlank() }
            ?: contentResolver.getType(uri)?.takeIf { it.isNotBlank() }
            ?: "application/octet-stream"
        return name to mimeType
    }

    private fun Intent.streamUri(): Uri? = if (android.os.Build.VERSION.SDK_INT >= 33) {
        getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(Intent.EXTRA_STREAM)
    } ?: clipData?.takeIf { it.itemCount == 1 }?.getItemAt(0)?.uri

    private fun app(): PlinkApplication = applicationContext as PlinkApplication

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private companion object {
        const val MAX_SHARED_TEXT_LENGTH = 64 * 1024
    }
}

class FileTransferAcceptanceActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var handle: String? = null
    private var pickerLaunched = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle = savedInstanceState?.getString(EXTRA_HANDLE) ?: intent.getStringExtra(EXTRA_HANDLE)
        pickerLaunched = savedInstanceState?.getBoolean(EXTRA_PICKER_LAUNCHED) == true
        val currentHandle = handle ?: return finish()
        if (intent.action == ACTION_DECLINE) {
            scope.launch {
                app().sessionController.declineIncomingFile(currentHandle)
                finish()
            }
            return
        }
        val offer = app().sessionController.pendingIncomingFile(currentHandle) ?: return finish()
        if (pickerLaunched) return
        pickerLaunched = true
        startActivityForResult(
            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = offer.mimeType
                putExtra(Intent.EXTRA_TITLE, offer.name)
            },
            REQUEST_DESTINATION
        )
    }

    @Deprecated("Uses platform result API for a minimal non-Compose activity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_DESTINATION) return
        val currentHandle = handle
        val resultData = data
        val uri = resultData?.data
        if (resultCode != RESULT_OK || currentHandle == null || resultData == null || uri == null) {
            if (currentHandle == null) return finish()
            scope.launch {
                app().sessionController.declineIncomingFile(currentHandle)
                finish()
            }
            return
        }
        val grantFlags = resultData.flags
        val persisted = grantFlags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0 &&
            grantFlags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0 && runCatching {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            true
        }.getOrDefault(false)
        if (!persisted) {
            val removed = runCatching { contentResolver.delete(uri, null, null) > 0 }.getOrDefault(false)
            showResult(if (removed) {
                "This document provider did not grant lasting write access."
            } else {
                "This provider did not grant lasting access. Remove the empty document if it remains."
            })
            scope.launch {
                app().sessionController.declineIncomingFile(currentHandle)
                finish()
            }
            return
        }
        scope.launch {
            val accepted = runCatching {
                app().sessionController.acceptIncomingFile(
                    currentHandle,
                    IncomingFileDestination(uri.toString(), newlyCreated = true, persistedPermission = persisted)
                )
            }.getOrDefault(false)
            if (!accepted) {
                val removed = runCatching { contentResolver.delete(uri, null, null) > 0 }.getOrDefault(false)
                releaseWritePermission(uri)
                Toast.makeText(
                    this@FileTransferAcceptanceActivity,
                    if (removed) "The file transfer expired." else "The transfer expired. Remove the empty document if it remains.",
                    Toast.LENGTH_LONG
                ).show()
            }
            finish()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(EXTRA_HANDLE, handle)
        outState.putBoolean(EXTRA_PICKER_LAUNCHED, pickerLaunched)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun app(): PlinkApplication = applicationContext as PlinkApplication

    private fun releaseWritePermission(uri: Uri) {
        runCatching {
            contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
    }

    private fun showResult(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }

    companion object {
        const val ACTION_ACCEPT = "app.plink.android.action.ACCEPT_FILE_TRANSFER"
        const val ACTION_DECLINE = "app.plink.android.action.DECLINE_FILE_TRANSFER"
        const val EXTRA_HANDLE = "file_transfer_handle"
        private const val EXTRA_PICKER_LAUNCHED = "file_transfer_picker_launched"
        private const val REQUEST_DESTINATION = 7
    }
}

class HandoffActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent.action) {
            ACTION_COPY -> intent.getStringExtra(EXTRA_TEXT)?.takeIf { it.isNotBlank() }?.let { text ->
                getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText("Plink", text))
            }
            ACTION_OPEN_URL -> intent.getStringExtra(EXTRA_URL)?.takeIf { it.isNotBlank() }?.let { url ->
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            }
        }
        finish()
    }

    companion object {
        const val ACTION_COPY = "app.plink.android.action.COPY_HANDOFF"
        const val ACTION_OPEN_URL = "app.plink.android.action.OPEN_HANDOFF_URL"
        const val EXTRA_TEXT = "handoff_text"
        const val EXTRA_URL = "handoff_url"
    }
}

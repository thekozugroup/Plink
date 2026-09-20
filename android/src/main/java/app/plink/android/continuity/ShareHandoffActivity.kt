package app.plink.android.continuity

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import app.plink.android.PlinkApplication

class ShareHandoffActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent.action) {
            Intent.ACTION_SEND -> sendSharedText()
        }
        finish()
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

    private companion object {
        const val MAX_SHARED_TEXT_LENGTH = 64 * 1024
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

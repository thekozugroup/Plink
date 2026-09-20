package app.plink.android.clipboard

/** In-memory state for one enabled connection. No clipboard history or durable retry. */
internal class ClipboardSyncPolicy {
    data class Epoch(val session: Long, val enableRevision: Long)
    data class Capture(val epoch: Epoch, val revision: Long)

    private var epoch: Epoch? = null
    private var revision = 0L
    private var baselined = false
    private var lastText: String? = null
    private var lastTimestamp = 0L
    private var remoteId: String? = null
    private var remoteText: String? = null

    @Synchronized fun begin(next: Epoch) {
        if (epoch == next) return
        clear()
        epoch = next
    }

    @Synchronized fun clear() {
        epoch = null
        revision++
        baselined = false
        lastText = null
        lastTimestamp = 0
        remoteId = null
        remoteText = null
    }

    @Synchronized fun capture(): Capture? = epoch?.let { Capture(it, revision) }

    @Synchronized fun isCurrent(capture: Capture): Boolean =
        epoch == capture.epoch && revision == capture.revision

    @Synchronized fun remoteApplied(current: Epoch, text: String, id: String) {
        if (epoch != current) begin(current)
        revision++ // A read already in flight must not echo or overwrite this write.
        remoteId = id
        remoteText = text
    }

    @Synchronized fun observe(
        capture: Capture,
        text: String?,
        timestamp: Long,
        sensitive: Boolean = false,
        origin: String? = null
    ): String? {
        if (!isCurrent(capture)) return null
        val accepted = text?.takeIf { !sensitive && acceptable(it) }
        val changed = accepted != lastText || timestamp != lastTimestamp
        val first = !baselined
        baselined = true
        lastText = accepted
        lastTimestamp = timestamp
        val echo = accepted != null && (origin == remoteId && remoteId != null || accepted == remoteText)
        if (changed) {
            revision++ // Supersede queued work for the previous clipboard revision.
            remoteId = null
            remoteText = null
        }
        return accepted?.takeIf { changed && !first && !echo }
    }

    companion object {
        const val MAX_TEXT_BYTES = 32_768

        // Existing protocol validators reject blank text. Do not trim or truncate other text.
        fun acceptable(text: String): Boolean = text.isNotBlank() &&
            text.length <= MAX_TEXT_BYTES && text.toByteArray(Charsets.UTF_8).size <= MAX_TEXT_BYTES
    }
}

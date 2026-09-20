package app.plink.android.services

import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import app.plink.android.continuity.MediaStateEvent
import java.util.UUID

class MediaSessionCollector(
    context: Context,
    private val emit: (MediaStateEvent) -> Unit
) {
    private val manager = context.getSystemService(MediaSessionManager::class.java)
    private val listenerComponent = ComponentName(context, PlinkNotificationListenerService::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ids = linkedMapOf<MediaController, String>()
    private val callbacks = linkedMapOf<MediaController, MediaController.Callback>()
    private var listening = false
    private val activeListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        refresh(controllers.orEmpty())
    }

    @Synchronized
    fun start() {
        if (listening) return
        listening = true
        try {
            manager.addOnActiveSessionsChangedListener(activeListener, listenerComponent, mainHandler)
            refresh(manager.getActiveSessions(listenerComponent))
        } catch (_: SecurityException) {
            runCatching { manager.removeOnActiveSessionsChangedListener(activeListener) }
            listening = false
        }
    }

    @Synchronized
    fun stop() {
        if (!listening) return
        listening = false
        runCatching { manager.removeOnActiveSessionsChangedListener(activeListener) }
        callbacks.forEach { (controller, callback) -> runCatching { controller.unregisterCallback(callback) } }
        callbacks.clear()
        ids.clear()
    }

    @Synchronized
    fun execute(sessionId: String, command: String) {
        val controller = ids.entries.firstOrNull { it.value == sessionId }?.key
            ?: throw IllegalArgumentException("Media session was not found.")
        val actions = controller.playbackState?.actions ?: 0L
        when (command) {
            "play" -> {
                require(actions and PlaybackState.ACTION_PLAY != 0L) { "Play is unavailable." }
                controller.transportControls.play()
            }
            "pause" -> {
                require(actions and PlaybackState.ACTION_PAUSE != 0L) { "Pause is unavailable." }
                controller.transportControls.pause()
            }
            "next" -> {
                require(actions and PlaybackState.ACTION_SKIP_TO_NEXT != 0L) { "Next is unavailable." }
                controller.transportControls.skipToNext()
            }
            "previous" -> {
                require(actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS != 0L) { "Previous is unavailable." }
                controller.transportControls.skipToPrevious()
            }
            else -> throw IllegalArgumentException("Unsupported media command.")
        }
    }

    @Synchronized
    private fun refresh(active: List<MediaController>) {
        val removed = callbacks.keys - active.toSet()
        removed.forEach { controller ->
            runCatching { controller.unregisterCallback(callbacks.remove(controller) ?: return@forEach) }
            val sessionId = ids.remove(controller) ?: return@forEach
            emit(MediaStateEvent(sessionId, "", "", false, false, false, false, false))
        }
        active.forEach { controller ->
            ids.getOrPut(controller) { UUID.randomUUID().toString() }
            if (callbacks[controller] == null) {
                val callback = object : MediaController.Callback() {
                    override fun onPlaybackStateChanged(state: PlaybackState?) = publish(controller)
                    override fun onMetadataChanged(metadata: MediaMetadata?) = publish(controller)
                    override fun onSessionDestroyed() {
                        val active = try {
                            manager.getActiveSessions(listenerComponent)
                        } catch (_: SecurityException) {
                            emptyList()
                        }
                        refresh(active)
                    }
                }
                callbacks[controller] = callback
                controller.registerCallback(callback, mainHandler)
            }
            publish(controller)
        }
    }

    @Synchronized
    private fun publish(controller: MediaController) {
        val sessionId = ids[controller] ?: return
        val state = controller.playbackState
        val actions = state?.actions ?: 0L
        val metadata = controller.metadata
        emit(
            MediaStateEvent(
                sessionId = sessionId,
                title = metadata?.getText(MediaMetadata.METADATA_KEY_TITLE)?.toString().orEmpty(),
                artist = metadata?.getText(MediaMetadata.METADATA_KEY_ARTIST)?.toString().orEmpty(),
                playing = state?.state == PlaybackState.STATE_PLAYING,
                canPlay = actions and PlaybackState.ACTION_PLAY != 0L,
                canPause = actions and PlaybackState.ACTION_PAUSE != 0L,
                canNext = actions and PlaybackState.ACTION_SKIP_TO_NEXT != 0L,
                canPrevious = actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS != 0L
            )
        )
    }
}

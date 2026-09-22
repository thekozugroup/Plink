package app.plink.android.services

import android.os.Handler
import android.os.Looper
import app.plink.android.notifications.NotificationActionRegistry
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

/** Listener ownership only; active snapshots are requested on lifecycle events, never polled. */
internal object SharedNotificationActions {
    val registry = NotificationActionRegistry().apply {
        onState = { SharedOutboundBridge.tryForward(it) }
        onRetireKey = { key -> SharedReplyRoutes.registry.removeByNotificationKey(key); SharedReplyActions.registry.removeByNotificationKey(key) }
    }
    @Volatile private var listener = WeakReference<PlinkNotificationListenerService>(null)
    private val posted = AtomicBoolean(false)
    private val forcePending = AtomicBoolean(false)
    private val handler by lazy { Handler(Looper.getMainLooper()) }

    fun attach(service: PlinkNotificationListenerService) { listener = WeakReference(service); requestRefresh() }
    fun detach(service: PlinkNotificationListenerService) {
        if (listener.get() === service) listener.clear()
    }
    fun requestRefresh(force: Boolean = false) {
        if (force) forcePending.set(true)
        if (!posted.compareAndSet(false, true)) return
        handler.post {
            posted.set(false)
            listener.get()?.refreshActionSnapshot(forcePending.getAndSet(false))
        }
    }
}

package app.plink.android.screen

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.plink.android.MainActivity
import app.plink.android.R
import java.util.concurrent.atomic.AtomicBoolean

internal data class CapturedScreenBitmap(val bitmap: Bitmap, val generation: Long)

class ScreenProjectionService : Service() {
    private val lock = Any()
    private val terminal = AtomicBoolean()
    private val finishScheduled = AtomicBoolean()
    private lateinit var captureThread: HandlerThread
    private lateinit var captureHandler: Handler
    private var startTicket: ScreenProjectionStartTicket? = null
    private val deliveredTickets = mutableSetOf<ScreenProjectionStartTicket>()
    private var releaseComplete = false
    private var serviceStartId: Int = 0
    private var projection: MediaProjection? = null
    private var callback: MediaProjection.Callback? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var latestBitmap: Bitmap? = null
    private var captureGeneration = 0L
    private var lastCopiedAtMillis = Long.MIN_VALUE
    private var receiverRegistered = false

    override fun onCreate() {
        super.onCreate()
        captureThread = HandlerThread("PlinkScreenCapture").also { it.start() }
        captureHandler = Handler(captureThread.looper)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                if (matchesOwnedStart(intent)) stopCapture(ScreenStopReason.USER)
                return START_NOT_STICKY
            }
            ACTION_START -> Unit
            else -> {
                stopIfUnused(startId)
                return START_NOT_STICKY
            }
        }
        if (Build.VERSION.SDK_INT < 34) {
            stopIfUnused(startId)
            return START_NOT_STICKY
        }

        val token = intent.getStringExtra(EXTRA_START_TOKEN) ?: run {
            stopIfUnused(startId)
            return START_NOT_STICKY
        }
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: run {
            stopIfUnused(startId)
            return START_NOT_STICKY
        }
        val streamId = intent.getStringExtra(EXTRA_STREAM_ID) ?: run {
            stopIfUnused(startId)
            return START_NOT_STICKY
        }
        val sessionGeneration = intent.getLongExtra(EXTRA_SESSION_GENERATION, -1)
        val ownerGeneration = intent.getLongExtra(EXTRA_OWNER_GENERATION, -1)
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val consentData = intent.intentExtra(EXTRA_CONSENT_DATA) ?: run {
            stopIfUnused(startId)
            return START_NOT_STICKY
        }
        val ticket = ScreenProjectionRuntime.claimDelivery(
            token = token,
            requestId = requestId,
            streamId = streamId,
            sessionGeneration = sessionGeneration,
            ownerGeneration = ownerGeneration,
            service = this
        ) ?: run {
            stopIfUnused(startId)
            return START_NOT_STICKY
        }
        var alreadyReleased = false
        val accepted = synchronized(lock) {
            serviceStartId = startId
            alreadyReleased = releaseComplete
            if (!alreadyReleased) deliveredTickets += ticket
            if (alreadyReleased || startTicket != null || terminal.get()) false else {
                startTicket = ticket
                true
            }
        }
        if (!accepted) {
            ScreenProjectionRuntime.rejectDeliveredStart(ticket)
            if (terminal.get()) stopSelfResult(startId)
            if (alreadyReleased) ScreenProjectionRuntime.completeStart(ticket, this)
            return START_NOT_STICKY
        }
        if (!ScreenProjectionRuntime.isStartCurrent(ticket, this)) {
            stopCapture(ScreenStopReason.DISCONNECTED)
            return START_NOT_STICKY
        }

        try {
            if (!captureHandler.post { initializeCapture(ticket, resultCode, consentData) }) {
                stopCapture(ScreenStopReason.CAPTURE_ERROR)
            }
        } catch (_: Exception) {
            stopCapture(ScreenStopReason.CAPTURE_ERROR)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopCapture(ScreenStopReason.CAPTURE_ERROR)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    internal fun stopIfOwned(ticket: ScreenProjectionStartTicket, reason: ScreenStopReason) {
        if (synchronized(lock) { startTicket === ticket }) stopCapture(reason)
    }

    internal fun takeLatest(ticket: ScreenProjectionStartTicket): CapturedScreenBitmap? {
        if (!interactiveAndUnlocked()) {
            stopCapture(ScreenStopReason.LOCKED)
            return null
        }
        return synchronized(lock) {
            if (startTicket !== ticket || terminal.get()) return@synchronized null
            latestBitmap?.let { CapturedScreenBitmap(it, captureGeneration) }.also { latestBitmap = null }
        }
    }

    internal fun isCaptureGenerationCurrent(ticket: ScreenProjectionStartTicket, generation: Long): Boolean =
        synchronized(lock) {
            startTicket === ticket && !terminal.get() && captureGeneration == generation
        }

    private fun initializeCapture(
        ticket: ScreenProjectionStartTicket,
        resultCode: Int,
        consentData: Intent
    ) {
        if (Build.VERSION.SDK_INT < 34) {
            stopCapture(ScreenStopReason.CAPTURE_ERROR)
            return
        }
        try {
            requireCurrent(ticket)
            if (!interactiveAndUnlocked()) error("Screen is locked.")
            startProjectionForeground(ticket)
            requireCurrent(ticket)
            val mediaProjection = getSystemService(MediaProjectionManager::class.java)
                .getMediaProjection(resultCode, consentData) ?: error("Projection unavailable.")
            synchronized(lock) { projection = mediaProjection }
            requireCurrent(ticket)

            val projectionCallback = object : MediaProjection.Callback() {
                override fun onStop() = stopCapture(ScreenStopReason.CONSENT_REVOKED)

                override fun onCapturedContentResize(width: Int, height: Int) {
                    captureHandler.post {
                        runCatching { resize(ticket, width, height) }
                            .onFailure { stopCapture(ScreenStopReason.CAPTURE_ERROR) }
                    }
                }

                override fun onCapturedContentVisibilityChanged(isVisible: Boolean) {
                    if (!isVisible) stopCapture(ScreenStopReason.HIDDEN)
                }
            }
            mediaProjection.registerCallback(projectionCallback, captureHandler)
            synchronized(lock) { callback = projectionCallback }
            requireCurrent(ticket)

            ContextCompat.registerReceiver(
                this,
                screenOffReceiver,
                IntentFilter(Intent.ACTION_SCREEN_OFF),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            synchronized(lock) { receiverRegistered = true }
            requireCurrent(ticket)

            val bounds = getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds
            val initial = ScreenFrameEncoder.boundedSize(bounds.width(), bounds.height())
            val generation = synchronized(lock) { captureGeneration }
            val imageReader = createReader(ticket, initial.width, initial.height, generation)
            synchronized(lock) { reader = imageReader }
            requireCurrent(ticket)

            val virtualDisplay = requireNotNull(
                mediaProjection.createVirtualDisplay(
                    "Plink screen preview",
                    initial.width,
                    initial.height,
                    resources.displayMetrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    imageReader.surface,
                    null,
                    captureHandler
                )
            ) { "Virtual display unavailable." }
            if (!isCurrent(ticket)) {
                virtualDisplay.release()
                error("Screen start was revoked.")
            }
            synchronized(lock) { display = virtualDisplay }
            if (!ScreenProjectionRuntime.started(ticket, this, generation)) {
                error("Screen start was revoked.")
            }
        } catch (_: Exception) {
            stopCapture(
                if (interactiveAndUnlocked()) ScreenStopReason.CAPTURE_ERROR else ScreenStopReason.LOCKED
            )
        }
    }

    private fun createReader(
        ticket: ScreenProjectionStartTicket,
        width: Int,
        height: Int,
        generation: Long
    ): ImageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2).also { imageReader ->
        imageReader.setOnImageAvailableListener({ source ->
            var image: android.media.Image? = null
            var bitmap: Bitmap? = null
            try {
                image = source.acquireLatestImage() ?: return@setOnImageAvailableListener
                if (!interactiveAndUnlocked()) {
                    stopCapture(ScreenStopReason.LOCKED)
                    return@setOnImageAvailableListener
                }
                val now = android.os.SystemClock.elapsedRealtime()
                val shouldCopy = synchronized(lock) {
                    startTicket === ticket && !terminal.get() && captureGeneration == generation && reader === source &&
                        (lastCopiedAtMillis == Long.MIN_VALUE ||
                            now - lastCopiedAtMillis >= COPY_INTERVAL_MILLIS)
                }
                if (!shouldCopy) return@setOnImageAvailableListener
                bitmap = ScreenFrameEncoder.copyCroppedRgba(image)
                synchronized(lock) {
                    if (startTicket === ticket && !terminal.get() &&
                        captureGeneration == generation && reader === source
                    ) {
                        latestBitmap?.recycle()
                        latestBitmap = bitmap
                        lastCopiedAtMillis = now
                        bitmap = null
                    }
                }
            } catch (_: Exception) {
                stopCapture(ScreenStopReason.CAPTURE_ERROR)
            } finally {
                bitmap?.recycle()
                image?.close()
            }
        }, captureHandler)
    }

    private fun resize(ticket: ScreenProjectionStartTicket, width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        requireCurrent(ticket)
        val bounded = ScreenFrameEncoder.boundedSize(width, height)
        val virtualDisplay: VirtualDisplay
        val oldReader: ImageReader
        val generation: Long
        synchronized(lock) {
            virtualDisplay = display ?: return
            oldReader = reader ?: return
            if (oldReader.width == bounded.width && oldReader.height == bounded.height) return
            captureGeneration++
            generation = captureGeneration
            reader = null
            latestBitmap?.recycle()
            latestBitmap = null
            lastCopiedAtMillis = Long.MIN_VALUE
        }
        ScreenProjectionRuntime.resized(ticket, this, generation)
        virtualDisplay.setSurface(null)
        oldReader.setOnImageAvailableListener(null, null)
        oldReader.close()
        requireCurrent(ticket)

        val newReader = createReader(ticket, bounded.width, bounded.height, generation)
        synchronized(lock) { reader = newReader }
        try {
            virtualDisplay.resize(bounded.width, bounded.height, resources.displayMetrics.densityDpi)
            virtualDisplay.setSurface(newReader.surface)
            requireCurrent(ticket)
        } catch (failure: Throwable) {
            synchronized(lock) { if (reader === newReader) reader = null }
            newReader.setOnImageAvailableListener(null, null)
            newReader.close()
            throw failure
        }
    }

    private fun stopCapture(reason: ScreenStopReason) {
        if (!terminal.compareAndSet(false, true)) return
        val ticket = synchronized(lock) { startTicket }
        if (ticket != null) ScreenProjectionRuntime.stopping(ticket, this, reason)
        if (!captureHandler.post { releaseCapture() }) releaseCapture()
    }

    private fun releaseCapture() {
        val resources = synchronized(lock) {
            captureGeneration++
            latestBitmap?.recycle()
            latestBitmap = null
            val values = CaptureResources(display, reader, projection, callback, receiverRegistered)
            display = null
            reader = null
            projection = null
            callback = null
            receiverRegistered = false
            values
        }
        runCatching { resources.display?.setSurface(null) }
        runCatching { resources.display?.release() }
        runCatching { resources.reader?.setOnImageAvailableListener(null, null) }
        runCatching { resources.reader?.close() }
        runCatching { resources.callback?.let { resources.projection?.unregisterCallback(it) } }
        if (resources.receiverRegistered) runCatching { unregisterReceiver(screenOffReceiver) }
        runCatching { resources.projection?.stop() }

        if (!captureHandler.post { finishCapture() }) finishCapture()
    }

    private fun finishCapture() {
        if (!finishScheduled.compareAndSet(false, true)) return
        captureThread.quitSafely()
        Thread({
            var interrupted = false
            while (captureThread.isAlive) {
                try {
                    captureThread.join()
                } catch (_: InterruptedException) {
                    interrupted = true
                }
            }
            runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
            val startId = synchronized(lock) { serviceStartId }
            if (startId != 0) {
                runCatching { stopSelfResult(startId) }
            } else {
                runCatching { stopSelf() }
            }
            val completedTickets = synchronized(lock) {
                releaseComplete = true
                deliveredTickets.toList().also { deliveredTickets.clear() }
            }
            completedTickets.forEach { ScreenProjectionRuntime.completeStart(it, this) }
            if (interrupted) Thread.currentThread().interrupt()
        }, "PlinkScreenCaptureStop").start()
    }

    private fun requireCurrent(ticket: ScreenProjectionStartTicket) {
        check(isCurrent(ticket)) { "Screen start was revoked." }
    }

    private fun isCurrent(ticket: ScreenProjectionStartTicket): Boolean =
        synchronized(lock) { startTicket === ticket && !terminal.get() } &&
            ScreenProjectionRuntime.isStartCurrent(ticket, this)

    private fun matchesOwnedStart(intent: Intent): Boolean = synchronized(lock) {
        val ticket = startTicket ?: return@synchronized false
        intent.getStringExtra(EXTRA_START_TOKEN) == ticket.token &&
            intent.getStringExtra(EXTRA_REQUEST_ID) == ticket.requestId &&
            intent.getStringExtra(EXTRA_STREAM_ID) == ticket.streamId &&
            intent.getLongExtra(EXTRA_SESSION_GENERATION, -1) == ticket.sessionGeneration &&
            intent.getLongExtra(EXTRA_OWNER_GENERATION, -1) == ticket.ownerGeneration
    }

    private fun stopIfUnused(startId: Int) {
        if (synchronized(lock) { startTicket == null }) stopSelfResult(startId)
    }

    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) stopCapture(ScreenStopReason.LOCKED)
        }
    }

    private fun interactiveAndUnlocked(): Boolean =
        getSystemService(PowerManager::class.java).isInteractive &&
            !getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked

    private fun startProjectionForeground(ticket: ScreenProjectionStartTicket) {
        val stopIntent = stopIntent(this, ticket)
        val stopAction = PendingIntent.getService(
            this,
            ticket.token.hashCode(),
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_plink)
            .setContentTitle("Sharing your screen with Mac")
            .setContentText("Tap Stop to end Plink screen preview")
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setSilent(true)
            .addAction(0, "Stop", stopAction)
            .build()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        )
    }

    private fun createNotificationChannel() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Screen preview", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private data class CaptureResources(
        val display: VirtualDisplay?,
        val reader: ImageReader?,
        val projection: MediaProjection?,
        val callback: MediaProjection.Callback?,
        val receiverRegistered: Boolean
    )

    companion object {
        private const val COPY_INTERVAL_MILLIS = 500L
        private const val ACTION_START = "app.plink.android.action.START_SCREEN_PREVIEW"
        private const val ACTION_STOP = "app.plink.android.action.STOP_SCREEN_PREVIEW"
        private const val EXTRA_START_TOKEN = "start_token"
        private const val EXTRA_REQUEST_ID = "request_id"
        private const val EXTRA_STREAM_ID = "stream_id"
        private const val EXTRA_SESSION_GENERATION = "session_generation"
        private const val EXTRA_OWNER_GENERATION = "owner_generation"
        private const val EXTRA_RESULT_CODE = "result_code"
        private const val EXTRA_CONSENT_DATA = "consent_data"
        private const val CHANNEL_ID = "screen_preview"
        private const val NOTIFICATION_ID = 45732

        fun start(
            context: Context,
            ticket: ScreenProjectionStartTicket,
            resultCode: Int,
            consentData: Intent
        ): Boolean {
            if (!ScreenProjectionRuntime.markLaunchIssued(ticket)) return false
            return runCatching {
                ContextCompat.startForegroundService(
                    context,
                    startIntent(context, ticket, resultCode, consentData)
                )
                true
            }.getOrElse {
                ScreenProjectionRuntime.launchFailed(ticket)
                false
            }
        }

        internal fun stop(context: Context, ticket: ScreenProjectionStartTicket) {
            runCatching { context.startService(stopIntent(context, ticket)) }
        }

        private fun startIntent(
            context: Context,
            ticket: ScreenProjectionStartTicket,
            resultCode: Int,
            consentData: Intent
        ) = Intent(context, ScreenProjectionService::class.java).apply {
            action = ACTION_START
            putTicket(ticket)
            putExtra(EXTRA_RESULT_CODE, resultCode)
            putExtra(EXTRA_CONSENT_DATA, consentData)
        }

        private fun stopIntent(context: Context, ticket: ScreenProjectionStartTicket) =
            Intent(context, ScreenProjectionService::class.java).apply {
                action = ACTION_STOP
                putTicket(ticket)
            }

        private fun Intent.putTicket(ticket: ScreenProjectionStartTicket) {
            putExtra(EXTRA_START_TOKEN, ticket.token)
            putExtra(EXTRA_REQUEST_ID, ticket.requestId)
            putExtra(EXTRA_STREAM_ID, ticket.streamId)
            putExtra(EXTRA_SESSION_GENERATION, ticket.sessionGeneration)
            putExtra(EXTRA_OWNER_GENERATION, ticket.ownerGeneration)
        }
    }
}

internal object ScreenProjectionRuntime {
    private val lock = Any()
    private var coordinator: ScreenPreviewCoordinator? = null
    private val lifecycles = ScreenProjectionLifecycles<ScreenProjectionService>()

    fun attach(value: ScreenPreviewCoordinator) {
        synchronized(lock) { coordinator = value }
    }

    fun registerStart(
        requestId: String,
        streamId: String,
        sessionGeneration: Long,
        ownerGeneration: Long
    ): ScreenProjectionStartTicket = lifecycles.register(requestId, streamId, sessionGeneration, ownerGeneration)

    fun markLaunchIssued(ticket: ScreenProjectionStartTicket): Boolean = lifecycles.markLaunchIssued(ticket)

    fun launchFailed(ticket: ScreenProjectionStartTicket) {
        lifecycles.launchFailed(ticket)?.stopIfOwned(ticket, ScreenStopReason.CAPTURE_ERROR)
    }

    fun claimDelivery(
        token: String,
        requestId: String,
        streamId: String,
        sessionGeneration: Long,
        ownerGeneration: Long,
        service: ScreenProjectionService
    ): ScreenProjectionStartTicket? = lifecycles.claimDelivery(
        token, requestId, streamId, sessionGeneration, ownerGeneration, service
    )

    fun rejectDeliveredStart(ticket: ScreenProjectionStartTicket) {
        synchronized(lock) { coordinator }?.projectionStartRejected(ticket)
        invalidate(ticket, ScreenStopReason.DISCONNECTED)
    }

    fun isStartCurrent(
        ticket: ScreenProjectionStartTicket,
        service: ScreenProjectionService
    ): Boolean {
        val registered = lifecycles.isCurrent(ticket, service)
        return registered && synchronized(lock) { coordinator }?.ownsProjectionStart(ticket) == true
    }

    fun started(
        ticket: ScreenProjectionStartTicket,
        service: ScreenProjectionService,
        captureGeneration: Long
    ): Boolean {
        if (!isStartCurrent(ticket, service)) return false
        val accepted = synchronized(lock) { coordinator }
            ?.projectionStarted(ticket, captureGeneration) == true
        if (!accepted) invalidate(ticket, ScreenStopReason.CAPTURE_ERROR)
        return accepted
    }

    fun resized(
        ticket: ScreenProjectionStartTicket,
        service: ScreenProjectionService,
        captureGeneration: Long
    ) {
        if (isStartCurrent(ticket, service)) {
            synchronized(lock) { coordinator }?.projectionResized(ticket, captureGeneration)
        }
    }

    fun takeLatest(ticket: ScreenProjectionStartTicket): CapturedScreenBitmap? {
        val service = lifecycles.currentOwner(ticket)
        return service?.takeLatest(ticket)
    }

    fun isCaptureGenerationCurrent(
        ticket: ScreenProjectionStartTicket,
        generation: Long
    ): Boolean {
        val service = lifecycles.currentOwner(ticket)
        return service?.isCaptureGenerationCurrent(ticket, generation) == true
    }

    fun stopping(
        ticket: ScreenProjectionStartTicket,
        service: ScreenProjectionService,
        reason: ScreenStopReason
    ) {
        if (!lifecycles.stopping(ticket, service)) return
        val owner = synchronized(lock) { coordinator }
        owner?.projectionStopped(ticket, reason)
    }

    fun invalidate(ticket: ScreenProjectionStartTicket, reason: ScreenStopReason) {
        lifecycles.invalidate(ticket)?.stopIfOwned(ticket, reason)
    }

    fun completeStart(ticket: ScreenProjectionStartTicket, service: ScreenProjectionService) {
        lifecycles.complete(ticket, service)
    }

    suspend fun awaitQuiescence() {
        lifecycles.awaitQuiescence()
    }
}

@Suppress("DEPRECATION")
private fun Intent.intentExtra(name: String): Intent? = if (Build.VERSION.SDK_INT >= 33) {
    getParcelableExtra(name, Intent::class.java)
} else {
    getParcelableExtra(name)
}

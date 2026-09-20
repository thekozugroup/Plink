package app.plink.android

import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.PlinkTime
import app.plink.android.services.SharedOutboundBridge
import app.plink.android.screen.ScreenFrameEncoder
import app.plink.android.screen.ScreenFrameEncoding
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlinx.coroutines.NonCancellable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.Base64
import java.util.UUID
import java.time.Instant
import java.util.Random

/** All media in this check comes from the debug pattern on an isolated emulator. */
internal suspend fun checkScreenRoundtrip(
    instrumentation: Instrumentation,
    arguments: Bundle,
    status: (String) -> Unit,
): List<String> {
    // Instrumentation starts its worker before Application.onCreate necessarily
    // returns. Wait for the main bind message before reading application owners.
    instrumentation.waitForIdleSync()
    val context = instrumentation.targetContext
    val key = Base64.getDecoder().decode(requireNotNull(arguments.getString("sessionKey")))
    val host = requireNotNull(arguments.getString("macHost"))
    val port = requireNotNull(arguments.getString("macPort")).toInt()
    val replyPort = requireNotNull(arguments.getString("replyPort")).toInt()
    val application = context.applicationContext as PlinkApplication
    withTimeout(5_000) {
        while (application.sessionRestoreState.value != SessionRestoreState.COMPLETE) delay(25)
    }
    val owner = try {
        ScreenPreviewTestSession.open(context, key, host, port, replyPort)
    } catch (failure: Throwable) {
        key.fill(0)
        throw failure
    }
    try {
        checkNativeFrameEncoding()
        status("SCREEN ENCODER CHECKS PASSED: real Bitmap JPEG encode and bounded noisy-frame fallback.")
        suspend fun signal(name: String) {
            SharedOutboundBridge.sendAwaitable(PlinkEnvelope(
                id = UUID.randomUUID().toString(), type = PlinkEventType.Ack,
                sentAt = PlinkTime.canonicalTimestamp(Instant.now()), sourceDeviceId = ScreenPreviewTestSession.PHONE_ID,
                targetDeviceId = ScreenPreviewTestSession.MAC_ID,
                payload = buildJsonObject { put("eventId", name); put("status", "executed") },
            ))
        }
        val main = instrumentation.startActivitySync(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        try {
            signal("screen-test-ready")
            status("SCREEN TEST READY: use Plink Share and normal Android screen consent on the owned emulator.")
            // The parent drives the visible consent flow. Never inject or reuse a
            // MediaProjection token, grant app-ops, or bypass the Android dialog.
            withTimeout(60_000) {
                while (!owner.isCapturing()) {
                    owner.requireNoCaptureError()
                    delay(50)
                }
            }
            status("SCREEN TEST CAPTURING: switching to synthetic pattern.")
            val pattern = instrumentation.startActivitySync(Intent().setClassName(
                context.packageName, "app.plink.android.debug.ScreenPreviewPatternActivity"
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            try {
                withTimeout(25_000) {
                    while (!owner.isStopped()) {
                        owner.requireNoCaptureError()
                        delay(50)
                    }
                }
                check(owner.isStopped()) { "Capture did not stop cleanly." }
                signal("screen-test-stopped")
                // The parent closes the process and checks no projection service,
                // test state, port mapping or instrumentation package survives.
                status("SCREEN TEST STOPPED: remote stop observed by Android.")
            } finally {
                instrumentation.runOnMainSync { pattern.finish() }
            }
        } finally {
            instrumentation.runOnMainSync { main.finish() }
        }
        return listOf("Native bounded JPEG encoder", "Consented emulator capture", "Remote screen stop observed")
    } finally {
        try {
            withContext(NonCancellable) { owner.close() }
            status("SCREEN TEST CLEANUP PASSED: session quiescent, preferences restored, owned state removed.")
        } finally { key.fill(0) }
    }
}

/** Uses Android's actual JPEG compressor, not a JVM Bitmap mock. */
private fun checkNativeFrameEncoding() {
    val flat = Bitmap.createBitmap(576, 1280, Bitmap.Config.ARGB_8888)
    try {
        flat.eraseColor(Color.BLUE)
        val encoded = ScreenFrameEncoder.encode(flat)
        check(encoded is ScreenFrameEncoding.Encoded)
        check(encoded.width == 576 && encoded.height == 1280 && encoded.jpeg.size <= 40_960)
    } finally { flat.recycle() }

    val noise = Bitmap.createBitmap(720, 1280, Bitmap.Config.ARGB_8888)
    try {
        val random = Random(9107)
        val pixels = IntArray(noise.width * noise.height) { random.nextInt() or (0xff shl 24) }
        noise.setPixels(pixels, 0, noise.width, 0, 0, noise.width, noise.height)
        when (val encoded = ScreenFrameEncoder.encode(noise)) {
            is ScreenFrameEncoding.Encoded -> {
                check(encoded.width == 360 && encoded.height == 640) { "Noisy capture did not use bounded fallback." }
                check(encoded.jpeg.size <= 40_960)
            }
            ScreenFrameEncoding.TooLarge -> Unit
        }
    } finally { noise.recycle() }
}

package app.plink.android

import android.app.Instrumentation
import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.os.Process
import android.os.UserHandle
import android.service.notification.StatusBarNotification
import app.plink.android.notifications.NotificationMapper
import app.plink.android.notifications.RemoteInputReplyExecutor
import app.plink.android.notifications.RemoteInputReplyRegistry
import app.plink.android.notifications.ReplyRouteRegistry
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.InMemoryFrameStateStore
import app.plink.android.security.FileFrameStateStore
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.PayloadPolicy
import app.plink.android.transport.SecureSocketPlinkClient
import app.plink.android.transport.SecureSocketPlinkServer
import app.plink.android.services.InboundCommandHandler
import java.time.Instant
import java.io.File
import java.util.UUID
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Platform tests use only synthetic PendingIntents and isolated transport identities. No screen, real notifications or saved pairings. */
class PlinkDeviceTestRunner : Instrumentation() {
    private var arguments = Bundle()
    private val checks = mutableListOf<String>()

    override fun onCreate(arguments: Bundle?) {
        this.arguments = arguments ?: Bundle()
        start()
    }

    override fun onStart() {
        val result = Bundle()
        val receiver = SyntheticReplyReceiver()
        targetContext.registerReceiver(receiver, IntentFilter("app.plink.TEST_REPLY"), Context.RECEIVER_NOT_EXPORTED)
        try {
            testRemoteInput()
            testProtectedAndDataOnlyActions()
            testDurableFrameState()
            if (arguments.containsKey("macPort")) {
                if (arguments.getString("mode") == "files") {
                    checks += runBlocking {
                        checkFileRoundtrip(targetContext, arguments) { message ->
                            sendStatus(1, Bundle().apply { putString("stream", "\n$message\n") })
                        }
                    }
                } else if (arguments.containsKey("replyPort")) testMacRoundtrip() else testMacTransport()
            }
            result.putString("stream", "\nPLINK DEVICE CHECKS PASSED: ${checks.joinToString(", ")}\n")
            result.putInt("checks", checks.size)
            targetContext.unregisterReceiver(receiver)
            finish(0, result)
        } catch (error: Throwable) {
            result.putString("stream", "\nPLINK DEVICE CHECKS FAILED: ${error.javaClass.simpleName}: ${error.message}\n")
            runCatching { targetContext.unregisterReceiver(receiver) }
            finish(1, result)
        }
    }

    private fun pendingIntent(): PendingIntent = PendingIntent.getBroadcast(
        targetContext, 9107, Intent("app.plink.TEST_REPLY").setPackage(targetContext.packageName),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
    )

    private fun notification(action: Notification.Action?): StatusBarNotification {
        val builder = Notification.Builder(targetContext, "plink-synthetic-never-posted")
            .setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle("Plink synthetic sender")
            .setContentText("Synthetic test message").setCategory(Notification.CATEGORY_MESSAGE)
        action?.let(builder::addAction)
        return StatusBarNotification(targetContext.packageName, targetContext.packageName, 9107, "plink-test",
            Process.myUid(), Process.myPid(), 0, builder.build(), Process.myUserHandle(), System.currentTimeMillis())
    }

    private fun reply(envelope: PlinkEnvelope, text: String): PlinkEnvelope = PlinkEnvelope(
        id = "test-reply", type = PlinkEventType.MessageReply, sentAt = Instant.now().toString(),
        sourceDeviceId = "test-mac", targetDeviceId = "test-pixel", requiresAck = true,
        payload = JsonObject(envelope.payload + mapOf("sourceEnvelopeId" to JsonPrimitive(envelope.id), "text" to JsonPrimitive(text)))
    )

    private fun testRemoteInput() {
        SyntheticReplyReceiver.reset()
        val routes = ReplyRouteRegistry()
        val actions = RemoteInputReplyRegistry()
        val mapper = NotificationMapper("test-pixel", "test-mac", routes, actions)
        val pending = pendingIntent()
        try {
            val input = RemoteInput.Builder("text").setAllowFreeFormInput(true).build()
            val action = Notification.Action.Builder(null, "Reply", pending).addRemoteInput(input).build()
            val handoff = requireNotNull(mapper.map(notification(action)))
            check(handoff.replyRoute != null && handoff.envelope.payload["canReply"] == JsonPrimitive(true))
            val executor = RemoteInputReplyExecutor(targetContext, routes, actions)
            val command = reply(handoff.envelope, "Plink synthetic reply ✓")
            executor.execute(command, "test-pixel")
            check(SyntheticReplyReceiver.latch.await(5, TimeUnit.SECONDS)) { "Synthetic reply PendingIntent was not delivered." }
            check(SyntheticReplyReceiver.text == "Plink synthetic reply ✓") { "RemoteInput text mismatch." }
            check(runCatching { executor.execute(command, "test-pixel") }.isFailure) { "Reply token was reused." }
            checks += "RemoteInput text delivered once"
            val replacement = requireNotNull(mapper.map(notification(action)))
            val readOnly = requireNotNull(mapper.map(notification(null))).envelope
            check(readOnly.payload["notificationKey"] == replacement.envelope.payload["notificationKey"])
            check(readOnly.payload["packageName"] == replacement.envelope.payload["packageName"])
            check(readOnly.payload["canReply"] == JsonPrimitive(false))
            PayloadPolicy.requireAcceptable(readOnly)
            check(runCatching { executor.execute(reply(replacement.envelope, "stale"), "test-pixel") }.isFailure)
            check(SyntheticReplyReceiver.count.get() == 1)
            checks += "Notification replacement revokes reply"
            val toRemove = requireNotNull(mapper.map(notification(action)))
            val removed = mapper.removed(notification(action)).envelope
            check(removed.payload["removed"] == JsonPrimitive(true))
            check(removed.payload["canReply"] == JsonPrimitive(false))
            check(removed.payload["notificationKey"] == toRemove.envelope.payload["notificationKey"])
            PayloadPolicy.requireAcceptable(removed)
            check(runCatching { executor.execute(reply(toRemove.envelope, "removed"), "test-pixel") }.isFailure)
            checks += "Keyed notification removal revokes reply"
        } finally { pending.cancel() }
    }

    private fun testProtectedAndDataOnlyActions() {
        val routes = ReplyRouteRegistry()
        val actions = RemoteInputReplyRegistry()
        val mapper = NotificationMapper("test-pixel", "test-mac", routes, actions)
        val pending = pendingIntent()
        try {
            val data = RemoteInput.Builder("image").setAllowFreeFormInput(false).setAllowDataType("image/png", true).build()
            val action = Notification.Action.Builder(null, "Photo", pending).addRemoteInput(data).build()
            check(mapper.map(notification(action))?.replyRoute == null)
            checks += "Data-only RemoteInput rejected"
            val text = RemoteInput.Builder("text").build()
            val protected = Notification.Action.Builder(null, "Protected", pending).addRemoteInput(text).setAuthenticationRequired(true).build()
            check(mapper.map(notification(protected))?.replyRoute == null)
            checks += "Authentication-required action rejected"
        } finally { pending.cancel() }
    }

    private fun testMacTransport() = runBlocking {
        val key = Base64.getDecoder().decode(requireNotNull(arguments.getString("sessionKey")))
        val port = requireNotNull(arguments.getString("macPort")).toInt()
        val envelope = PlinkEnvelope(id = "pixel-device-check", type = PlinkEventType.DeviceStatus,
            sentAt = Instant.now().toString(), sourceDeviceId = "test-pixel", targetDeviceId = "test-mac",
            payload = buildJsonObject { put("batteryLevel", 73); put("charging", true); put("network", "test") })
        SecureSocketPlinkClient(arguments.getString("macHost") ?: "127.0.0.1", port,
            EncryptedFrameCodec(key), InMemoryFrameStateStore()).send(envelope)
        checks += "Android encrypted frame sent to Mac"
    }

    private fun testDurableFrameState() {
        val directory = File(targetContext.cacheDir, "plink-instrumentation-${UUID.randomUUID()}")
        try {
            val first = FileFrameStateStore(directory)
            check(first.reserveSequence("synthetic-test") == 1L)
            first.accept("synthetic-test", 2, "second")
            val restored = FileFrameStateStore(directory)
            check(restored.reserveSequence("synthetic-test") == 2L)
            check(runCatching { restored.accept("synthetic-test", 2, "second") }.isFailure)
            restored.accept("synthetic-test", 1, "first")
            check(runCatching { FileFrameStateStore(directory).accept("synthetic-test", 1, "first") }.isFailure)
            checks += "Android filesystem retains counters and replay rejection across store recreation"
        } finally {
            check(directory.deleteRecursively()) { "Test frame-state cleanup failed" }
        }
    }

    private fun testMacRoundtrip() = runBlocking {
        SyntheticReplyReceiver.reset()
        val key = Base64.getDecoder().decode(requireNotNull(arguments.getString("sessionKey")))
        val codec = EncryptedFrameCodec(key)
        val state = InMemoryFrameStateStore()
        val server = SecureSocketPlinkServer(requireNotNull(arguments.getString("replyPort")).toInt(),
            codec, state, expectedSourceDeviceId = "test-mac", expectedTargetDeviceId = "test-pixel")
        val client = SecureSocketPlinkClient(arguments.getString("macHost") ?: "127.0.0.1",
            requireNotNull(arguments.getString("macPort")).toInt(), codec, state)
        val routes = ReplyRouteRegistry()
        val actions = RemoteInputReplyRegistry()
        val pending = pendingIntent()
        try {
            withTimeout(20_000) {
                server.start()
                val command = async { server.receiveOnce() }
                val input = RemoteInput.Builder("text").setAllowFreeFormInput(true).build()
                val action = Notification.Action.Builder(null, "Reply", pending).addRemoteInput(input).build()
                val mapper = NotificationMapper("test-pixel", "test-mac", routes, actions)
                val message = requireNotNull(mapper.map(notification(action))).envelope
                client.send(message)
                val received = command.await()
                val executor = RemoteInputReplyExecutor(targetContext, routes, actions)
                InboundCommandHandler("test-pixel", "test-mac", executeReply = { reply ->
                    executor.execute(reply, "test-pixel")
                    check(SyntheticReplyReceiver.latch.await(5, TimeUnit.SECONDS))
                    check(SyntheticReplyReceiver.text == "Plink encrypted roundtrip ✓")
                    check(SyntheticReplyReceiver.count.get() == 1)
                }, executeMedia = { _, _ -> error("Unexpected media command") }, send = { outcome ->
                    check(outcome.type == PlinkEventType.Ack) { "RemoteInput execution failed" }
                    client.send(outcome)
                }).handle(received)
                check(runCatching { executor.execute(received, "test-pixel") }.isFailure)
                checks += "Encrypted Android–Swift reply roundtrip, real RemoteInput delivery and execution ack"
            }
        } finally {
            server.close()
            pending.cancel()
            key.fill(0)
        }
    }
}

class SyntheticReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence("text")?.toString()
        count.incrementAndGet()
        latch.countDown()
    }
    companion object {
        @Volatile var text: String? = null
        @Volatile var latch = CountDownLatch(1)
        val count = AtomicInteger(0)
        fun reset() { text = null; latch = CountDownLatch(1); count.set(0) }
    }
}

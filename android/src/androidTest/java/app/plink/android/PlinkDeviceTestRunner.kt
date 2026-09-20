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
import app.plink.android.notifications.ReplyCapabilityGeneration
import app.plink.android.notifications.ReplyDispatchLock
import app.plink.android.notifications.InboundReplyValidator
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import app.plink.android.security.InMemoryFrameStateStore
import app.plink.android.security.FileFrameStateStore
import app.plink.android.security.EncryptedFrameCodec
import app.plink.android.security.PayloadPolicy
import app.plink.android.transport.SecureSocketPlinkClient
import app.plink.android.transport.SecureSocketPlinkServer
import app.plink.android.services.InboundCommandHandler
import app.plink.android.services.SharedReplyDispatchAuthority
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Synthetic platform checks use isolated transport identities and never message real recipients. */
class PlinkDeviceTestRunner : Instrumentation() {
    private var arguments = Bundle()
    private val checks = mutableListOf<String>()
    private val syntheticGeneration = ReplyCapabilityGeneration(1, 91)
    private val exactReplyText = "\t  Plink encrypted roundtrip ✓\nCafe\u0301 👩‍💻\n  "

    override fun onCreate(arguments: Bundle?) {
        this.arguments = arguments ?: Bundle()
        start()
    }

    override fun onStart() {
        val result = Bundle()
        val receiver = SyntheticReplyReceiver()
        targetContext.registerReceiver(receiver, IntentFilter("app.plink.TEST_REPLY"), Context.RECEIVER_NOT_EXPORTED)
        try {
            if (arguments.getString("mode") == "screen") {
                checks += runBlocking {
                    checkScreenRoundtrip(this@PlinkDeviceTestRunner, arguments) { message ->
                        sendStatus(1, Bundle().apply { putString("stream", "\n$message\n") })
                    }
                }
                result.putString("stream", "\nPLINK DEVICE CHECKS PASSED: ${checks.joinToString(", ")}\n")
                result.putInt("checks", checks.size)
                targetContext.unregisterReceiver(receiver)
                finish(0, result)
                return
            }
            testRemoteInput()
            testProtectedAndDataOnlyActions()
            testReplyAuthorityRevocation()
            testReplyReconnectAndFailure()
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
        val actions = syntheticActions()
        val mapper = NotificationMapper("test-pixel", "test-mac", routes, actions)
        val pending = pendingIntent()
        try {
            val input = RemoteInput.Builder("text").setAllowFreeFormInput(true).build()
            val action = Notification.Action.Builder(null, "Reply", pending).addRemoteInput(input).build()
            val handoff = requireNotNull(mapper.map(notification(action)))
            check(handoff.replyRoute != null && handoff.envelope.payload["canReply"] == JsonPrimitive(true))
            val executor = syntheticExecutor(routes, actions)
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
        val actions = syntheticActions()
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

    // Synthetic tests opt into explicit authority. Production has no allow-all default.
    private fun syntheticActions() = RemoteInputReplyRegistry(
        capabilityGeneration = { syntheticGeneration }
    )

    private fun syntheticExecutor(routes: ReplyRouteRegistry, actions: RemoteInputReplyRegistry) =
        RemoteInputReplyExecutor(targetContext, routes, actions) { action, reply ->
            action.capabilityGeneration == syntheticGeneration && reply.route.pairedDeviceId == "test-mac"
        }

    private fun <T> onMain(block: () -> T): T {
        var result: Result<T>? = null
        runOnMainSync { result = runCatching(block) }
        return requireNotNull(result).getOrThrow()
    }

    private fun testReplyAuthorityRevocation() = runBlocking {
        val scenarios = listOf("disconnect", "destroy", "denied", "unknown", "disabled", "session", "peer", "queued")
        for (scenario in scenarios) {
            SyntheticReplyReceiver.reset()
            val routes = ReplyRouteRegistry()
            val actions = RemoteInputReplyRegistry(capabilityGeneration = SharedReplyDispatchAuthority::capture)
            var access: Boolean? = true
            var messages = true
            var peer = "test-mac"
            val pending = pendingIntent()
            try {
                val input = RemoteInput.Builder("text").setAllowFreeFormInput(true).build()
                val action = Notification.Action.Builder(null, "Reply", pending).addRemoteInput(input).build()
                val mapper = NotificationMapper("test-pixel", "test-mac", routes, actions)
                val message = onMain {
                    ReplyDispatchLock.serialized {
                        SharedReplyDispatchAuthority.listenerConnected()
                        SharedReplyDispatchAuthority.sessionChanged(91, active = true)
                        requireNotNull(mapper.map(notification(action))).envelope
                    }
                }
                val command = reply(message, exactReplyText)
                // A valid receiver preflight must not authorize a later, queued dispatch.
                InboundReplyValidator.validate(command, routes, "test-pixel")
                onMain {
                    ReplyDispatchLock.serialized {
                        when (scenario) {
                            "disconnect", "destroy", "queued" -> {
                                SharedReplyDispatchAuthority.listenerDisconnected()
                                routes.clear()
                                actions.clear()
                            }
                            "denied" -> access = false
                            "unknown" -> access = null
                            "disabled" -> messages = false
                            "session" -> SharedReplyDispatchAuthority.sessionChanged(92, active = true)
                            "peer" -> peer = "another-mac"
                        }
                    }
                }
                val executor = RemoteInputReplyExecutor(targetContext, routes, actions) { live, inbound ->
                    access == true && messages && inbound.route.pairedDeviceId == peer &&
                        SharedReplyDispatchAuthority.isCurrent(live.capabilityGeneration)
                }
                val outcomes = mutableListOf<PlinkEnvelope>()
                val handler = InboundCommandHandler("test-pixel", "test-mac", executeReply = {
                    withContext(Dispatchers.Main.immediate) { executor.execute(it, "test-pixel") }
                }, executeMedia = { _, _ -> error("Unexpected media") }, send = { outcomes += it })
                handler.handle(command)
                handler.handle(command)
                check(outcomes.size == 2 && outcomes.all { it.type == PlinkEventType.Error }) { scenario }
                check(!SyntheticReplyReceiver.latch.await(150, TimeUnit.MILLISECONDS)) { "Revoked $scenario reply sent" }
                check(SyntheticReplyReceiver.count.get() == 0 && routes.size() == 0 && actions.size() == 0) { scenario }
            } finally {
                pending.cancel()
                onMain {
                    ReplyDispatchLock.serialized {
                        SharedReplyDispatchAuthority.listenerDisconnected()
                        SharedReplyDispatchAuthority.sessionChanged(0, active = false)
                    }
                }
            }
        }
        checks += "Synthetic final-dispatch lifecycle, permission, feature, session, peer and queued revocations reject without sends or executed acks"
    }

    private fun testReplyReconnectAndFailure() = runBlocking {
        SyntheticReplyReceiver.reset()
        val routes = ReplyRouteRegistry()
        val actions = RemoteInputReplyRegistry(capabilityGeneration = SharedReplyDispatchAuthority::capture)
        val pending = pendingIntent()
        try {
            val input = RemoteInput.Builder("text").setAllowFreeFormInput(true).build()
            val action = Notification.Action.Builder(null, "Reply", pending).addRemoteInput(input).build()
            val mapper = NotificationMapper("test-pixel", "test-mac", routes, actions)
            fun post() = onMain { ReplyDispatchLock.serialized { requireNotNull(mapper.map(notification(action))).envelope } }
            onMain { ReplyDispatchLock.serialized {
                SharedReplyDispatchAuthority.listenerConnected()
                SharedReplyDispatchAuthority.sessionChanged(91, active = true)
            } }
            val old = reply(post(), exactReplyText)
            val executor = RemoteInputReplyExecutor(targetContext, routes, actions) { live, inbound ->
                inbound.route.pairedDeviceId == "test-mac" && SharedReplyDispatchAuthority.isCurrent(live.capabilityGeneration)
            }
            onMain { ReplyDispatchLock.serialized {
                SharedReplyDispatchAuthority.listenerDisconnected()
                routes.clear()
                actions.clear()
                SharedReplyDispatchAuthority.listenerConnected()
            } }
            check(onMain { runCatching { executor.execute(old, "test-pixel") }.isFailure })
            val fresh = reply(post(), exactReplyText)
            check(fresh.payload["replyToken"] != old.payload["replyToken"])
            var outcomeAttempts = 0
            val handler = InboundCommandHandler("test-pixel", "test-mac", executeReply = {
                withContext(Dispatchers.Main.immediate) { executor.execute(it, "test-pixel") }
            }, executeMedia = { _, _ -> error("Unexpected media") }, send = {
                outcomeAttempts += 1
                error("Synthetic outcome transport unavailable")
            })
            check(runCatching { handler.handle(fresh) }.isFailure)
            check(outcomeAttempts == 1) { "Outcome failure caused automatic retry" }
            check(SyntheticReplyReceiver.latch.await(5, TimeUnit.SECONDS))
            check(SyntheticReplyReceiver.text?.toByteArray(Charsets.UTF_8)
                ?.contentEquals(exactReplyText.toByteArray(Charsets.UTF_8)) == true)
            check(onMain { runCatching { executor.execute(fresh, "test-pixel") }.isFailure })
            check(onMain { runCatching { executor.execute(old, "test-pixel") }.isFailure })
            val cancelled = reply(post(), "cancelled")
            pending.cancel()
            val outcomes = mutableListOf<PlinkEnvelope>()
            val cancelledHandler = InboundCommandHandler("test-pixel", "test-mac", executeReply = {
                withContext(Dispatchers.Main.immediate) { executor.execute(it, "test-pixel") }
            }, executeMedia = { _, _ -> error("Unexpected media") }, send = { outcomes += it })
            cancelledHandler.handle(cancelled)
            cancelledHandler.handle(cancelled)
            check(outcomes.size == 2 && outcomes.all { it.type == PlinkEventType.Error })
            check(SyntheticReplyReceiver.count.get() == 1 && routes.size() == 0 && actions.size() == 0)
            checks += "Reconnect issues a fresh one-time route, exact UTF-8 survives, and send failures never restore consumed routes"
        } finally {
            pending.cancel()
            onMain { ReplyDispatchLock.serialized {
                SharedReplyDispatchAuthority.listenerDisconnected()
                SharedReplyDispatchAuthority.sessionChanged(0, active = false)
            } }
        }
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
        val actions = syntheticActions()
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
                val executor = syntheticExecutor(routes, actions)
                InboundCommandHandler("test-pixel", "test-mac", executeReply = { reply ->
                    executor.execute(reply, "test-pixel")
                    check(SyntheticReplyReceiver.latch.await(5, TimeUnit.SECONDS))
                    check(SyntheticReplyReceiver.text?.toByteArray(Charsets.UTF_8)
                        ?.contentEquals(exactReplyText.toByteArray(Charsets.UTF_8)) == true)
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

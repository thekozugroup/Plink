package app.plink.android

import android.app.Instrumentation
import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Process
import android.os.UserHandle
import android.service.notification.StatusBarNotification
import app.plink.android.notifications.*
import app.plink.android.protocol.NotificationActionsPolicy
import app.plink.android.protocol.PlinkEnvelope
import app.plink.android.protocol.PlinkEventType
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Never posts a notification; every PendingIntent targets this test's own receiver. */
internal fun checkNotificationActions(context: Context, instrumentation: Instrumentation,
                                      producedOffer: (String) -> Unit = {}): List<String> {
    val checks = mutableListOf<String>()
    val broadcast = "app.plink.SYNTHETIC_ACTION_24"
    data class Delivery(val marker: String?, val results: Map<String, String>, val source: Int)
    val received = LinkedBlockingQueue<Delivery>()
    val pending = mutableListOf<PendingIntent>()
    val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val results = RemoteInput.getResultsFromIntent(intent)
            received.add(Delivery(intent.getStringExtra("marker"),
                results?.keySet()?.associateWith { results.getCharSequence(it).toString() }.orEmpty(),
                RemoteInput.getResultsSource(intent)))
        }
    }
    context.registerReceiver(receiver, IntentFilter(broadcast), Context.RECEIVER_NOT_EXPORTED)
    var requestCode = 24_000
    var notificationId = 24_000
    var clock = System.currentTimeMillis()
    var unlocked: Boolean? = true
    val generation = ReplyCapabilityGeneration(24, 240)
    val registry = NotificationActionRegistry { clock }
    val routes = ReplyRouteRegistry()
    val replies = RemoteInputReplyRegistry(capabilityGeneration = { generation })
    val mapper = NotificationMapper("synthetic-phone", "synthetic-mac", routes, replies,
        notificationActions = registry, actionContext = context, actionUserUnlocked = { unlocked })
    fun <T> main(block: () -> T): T {
        var result: Result<T>? = null
        instrumentation.runOnMainSync { result = runCatching { ReplyDispatchLock.serialized(block) } }
        return requireNotNull(result).getOrThrow()
    }
    fun intent(marker: String, mutable: Boolean = true): PendingIntent = PendingIntent.getBroadcast(
        context, requestCode++, Intent(broadcast).setPackage(context.packageName).putExtra("marker", marker),
        PendingIntent.FLAG_UPDATE_CURRENT or if (mutable) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE
    ).also(pending::add)
    fun action(label: String, marker: String, inputs: List<RemoteInput> = emptyList(),
               auth: Boolean = false, mutable: Boolean = true): Notification.Action {
        val builder = Notification.Action.Builder(null, label, intent(marker, mutable))
        inputs.forEach(builder::addRemoteInput)
        return builder.setAuthenticationRequired(auth).build()
    }
    fun notification(actions: List<Notification.Action>, id: Int = notificationId++): StatusBarNotification {
        val builder = Notification.Builder(context, "synthetic-never-posted")
            .setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle("Synthetic sender")
            .setContentText("Synthetic action checks").setCategory(Notification.CATEGORY_MESSAGE)
        actions.forEach(builder::addAction)
        return StatusBarNotification(context.packageName, context.packageName, id, "synthetic-actions",
            Process.myUid(), Process.myPid(), 0, builder.build(), Process.myUserHandle(), clock)
    }
    fun map(sbn: StatusBarNotification) = main { requireNotNull(mapper.map(sbn)).envelope }
        .also { producedOffer(it.encode()) }
    fun command(type: String, payload: JsonObject) = PlinkEnvelope(
        id = UUID.randomUUID().toString(), type = type, sentAt = Instant.ofEpochMilli(clock).toString(),
        sourceDeviceId = "synthetic-mac", targetDeviceId = "synthetic-phone", requiresAck = true, payload = payload)
    fun enable(offer: PlinkEnvelope) = command(NotificationActionsPolicy.Enable, buildJsonObject {
        put("actionsVersion", 1); put("actionsSession", offer.payload.getValue("actionsSession"))
    })
    fun invoke(offer: PlinkEnvelope, index: Int = 0, text: String? = null) = command(NotificationActionsPolicy.Invoke, buildJsonObject {
        put("actionsVersion", 1); put("actionsSession", offer.payload.getValue("actionsSession"))
        put("actionsEpoch", offer.payload.getValue("actionsEpoch")); put("sourceEnvelopeId", offer.id)
        put("packageName", offer.payload.getValue("packageName")); put("notificationKey", offer.payload.getValue("notificationKey"))
        put("actionIndex", index); put("actionToken", offer.payload.getValue("action${index}Token"))
        text?.let { put("text", it) }
    })
    fun dispatch(command: PlinkEnvelope): PlinkEnvelope {
        val result = main { registry.handle(command, generation.sessionGeneration, authorized = { true }) }
        check(result.type in setOf(PlinkEventType.Ack, PlinkEventType.Error))
        check(result.payload["eventId"] == JsonPrimitive(command.id))
        check(result.payload["action"] == JsonPrimitive(command.type))
        check(result.payload["actionsVersion"] == JsonPrimitive(1))
        check(result.payload["actionsSession"] == command.payload["actionsSession"])
        check(result.sourceDeviceId == "synthetic-phone" && result.targetDeviceId == "synthetic-mac")
        check(!result.requiresAck)
        return result
    }
    fun status(result: PlinkEnvelope, expected: String) {
        val success = expected in setOf("enabled", "dispatched")
        check(result.type == if (success) PlinkEventType.Ack else PlinkEventType.Error)
        val key = if (success) "status" else "code"
        check(result.payload[key]?.jsonPrimitive?.content == expected) { "Unexpected action outcome; expected $expected" }
    }
    fun delivery(marker: String, text: String? = null, key: String = "reply-field") {
        val value = requireNotNull(received.poll(5, TimeUnit.SECONDS)) { "Synthetic receiver did not receive dispatch" }
        check(value.marker == marker) { "Wrong synthetic action receiver" }
        check(value.results == if (text == null) emptyMap() else mapOf(key to text)) { "RemoteInput result fields/text differ" }
        if (text != null) check(value.source == RemoteInput.SOURCE_FREE_FORM_INPUT)
    }
    fun noDelivery() {
        instrumentation.waitForIdleSync()
        check(received.poll(150, TimeUnit.MILLISECONDS) == null) { "Rejected or consumed action dispatched" }
    }
    fun legacy(offer: PlinkEnvelope, text: String): PlinkEnvelope = command(PlinkEventType.MessageReply,
        JsonObject(offer.payload + mapOf("sourceEnvelopeId" to JsonPrimitive(offer.id), "text" to JsonPrimitive(text))))
    val legacyExecutor = RemoteInputReplyExecutor(context, routes, replies) { live, reply ->
        live.capabilityGeneration == generation && reply.route.pairedDeviceId == "synthetic-mac"
    }
    try {
        main {
            registry.beginSession("synthetic-phone", "synthetic-mac", generation.sessionGeneration)
            registry.setListenerAvailable(true); registry.setFeatureEnabled(true)
        }
        val textInput = RemoteInput.Builder("reply-field").setLabel("Message").build()
        val callMarkers: List<Triple<String, String, (Notification) -> Unit>> = listOf(
            Triple("category", PlinkEventType.CallRinging, { n -> n.category = Notification.CATEGORY_CALL }),
            Triple("template", PlinkEventType.CallRinging, { n ->
                n.category = null; n.extras.putString("android.template", "android.app.Notification\$CallStyle")
            }),
            Triple("incoming-type", PlinkEventType.CallRinging, { n ->
                n.category = null; n.extras.putInt("android.callType", 1)
            }),
            Triple("ongoing-type", PlinkEventType.CallEnded, { n ->
                n.category = null; n.extras.putInt("android.callType", 2)
            }),
            Triple("screening-type", PlinkEventType.CallEnded, { n ->
                n.category = null; n.extras.putInt("android.callType", 3)
            }),
            Triple("category-wrong-type", PlinkEventType.CallRinging, { n ->
                n.category = Notification.CATEGORY_CALL; n.extras.putString("android.callType", "1")
            }),
            Triple("template-wrong-type", PlinkEventType.CallRinging, { n ->
                n.category = null; n.extras.putString("android.template", "android.app.Notification\$CallStyle")
                n.extras.putLong("android.callType", 1L)
            })
        )
        fun retirement(handoff: NotificationHandoff, sbn: StatusBarNotification): PlinkEnvelope {
            val retired = requireNotNull(handoff.retirement) { "Call handoff lacks versioned retirement" }
            check(retired.type == PlinkEventType.MessageReceived && NotificationActionsPolicy.hasValidOffer(retired))
            check(retired.payload["removed"] == JsonPrimitive(true))
            check(retired.payload["actionsCount"] == JsonPrimitive(0))
            check(retired.payload["actionsOverflowCount"] == JsonPrimitive(0))
            check(retired.payload["notificationKey"] == JsonPrimitive(sbn.key))
            check(retired.payload["packageName"] == JsonPrimitive(sbn.packageName))
            check(retired.id != handoff.envelope.id)
            check(retired.payload.keys.none { it == "replyToken" || it.matches(Regex("action[0-9]+Token")) })
            producedOffer(retired.encode())
            return retired
        }
        for ((name, expectedType, mark) in callMarkers) {
            val sbn = notification(listOf(action("Synthetic answer", "never-call-$name", mutable = false)))
            mark(sbn.notification)
            val handoff = main { requireNotNull(mapper.map(sbn)) }
            val mapped = handoff.envelope
            check(mapped.type == expectedType) { "Call marker $name escaped expected call lifecycle" }
            check("actionsVersion" !in mapped.payload && "replyToken" !in mapped.payload) {
                "Call marker $name exposed generic/reply capability"
            }
            val postedRetirement = retirement(handoff, sbn)
            val removedHandoff = main { mapper.removed(sbn) }
            val removed = removedHandoff.envelope
            check(removed.type == PlinkEventType.CallEnded && "actionsVersion" !in removed.payload) {
                "Call marker $name removal disagrees with posting"
            }
            check(retirement(removedHandoff, sbn).payload.getValue("actionsRevision").jsonPrimitive.long >
                postedRetirement.payload.getValue("actionsRevision").jsonPrimitive.long)
        }
        noDelivery()
        checks += "Category, exact CallStyle and integer call types exclude generic actions on post and removal"

        // A call transition must retire both aliases even when no incoming event is emitted.
        for ((name, _, mark) in callMarkers) {
            for (removeDirectly in listOf(false, true)) {
                val sbn = notification(listOf(action("Synthetic reply", "never-old-$name", listOf(textInput))))
                val old = map(sbn)
                status(dispatch(enable(old)), "enabled")
                val token = old.payload.getValue("replyToken").jsonPrimitive.content
                val snapshot = main { requireNotNull(registry.captureSnapshot()) }
                mark(sbn.notification)
                val callHandoff = main { requireNotNull(if (removeDirectly) mapper.removed(sbn) else mapper.map(sbn)) }
                val retired = retirement(callHandoff, sbn)
                check(retired.payload.getValue("actionsRevision").jsonPrimitive.long > old.payload.getValue("actionsRevision").jsonPrimitive.long)
                status(dispatch(invoke(old, text = "Synthetic stale reply")), "stale_action")
                check(main { routes.peek(token) } == null)
                check(runCatching { main { legacyExecutor.execute(legacy(old, "Synthetic stale reply"), "synthetic-phone") } }.isFailure)
                check(!main { registry.canApplySnapshot(snapshot, sbn.key) }) {
                    "Call transition $name failed to invalidate old snapshot"
                }
                val newer = map(notification(listOf(action("New ordinary", "new-after-$name", mutable = false)), sbn.id))
                check(newer.payload.getValue("actionsRevision").jsonPrimitive.long > retired.payload.getValue("actionsRevision").jsonPrimitive.long)
                status(dispatch(invoke(newer)), "dispatched"); delivery("new-after-$name")
            }
        }
        noDelivery()
        checks += "Same-key call update/removal revokes v1 and legacy aliases and invalidates captured snapshot"

        val ordinaryMarkers: List<Pair<String, (Notification) -> Unit>> = listOf(
            "voicemail" to { n -> n.category = "voicemail" },
            "ongoing-only" to { n -> n.category = null; n.flags = n.flags or Notification.FLAG_ONGOING_EVENT },
            "unknown-type" to { n -> n.category = null; n.extras.putInt("android.callType", 99) },
            "zero-type" to { n -> n.category = null; n.extras.putInt("android.callType", 0) },
            "string-type" to { n -> n.category = null; n.extras.putString("android.callType", "1") },
            "long-type" to { n -> n.category = null; n.extras.putLong("android.callType", 1L) },
            "boolean-type" to { n -> n.category = null; n.extras.putBoolean("android.callType", true) },
            "wrong-template-type" to { n -> n.category = null; n.extras.putInt("android.template", 1) },
            "near-template" to { n -> n.category = null; n.extras.putString("android.template", "android.app.Notification\$CallStyleExtra") }
        )
        for ((name, mark) in ordinaryMarkers) {
            // An English call-like label is deliberately not classification authority.
            val sbn = notification(listOf(action("Answer", "ordinary-$name", mutable = false)))
            mark(sbn.notification)
            val ordinaryHandoff = main { requireNotNull(mapper.map(sbn)) }
            check(ordinaryHandoff.retirement == null)
            val ordinary = ordinaryHandoff.envelope.also { producedOffer(it.encode()) }
            check(ordinary.type == PlinkEventType.MessageReceived && ordinary.payload["actionsCount"] == JsonPrimitive(1)) {
                "Ordinary control $name lost its action"
            }
            status(dispatch(enable(ordinary)), "enabled")
            status(dispatch(invoke(ordinary)), "dispatched"); delivery("ordinary-$name")
        }
        noDelivery()
        checks += "Voicemail, ordinary actions and malformed/unknown metadata remain generic; labels and ongoing flag are not authority"
        main { registry.beginSession("synthetic-phone", "synthetic-mac", generation.sessionGeneration) }
        val cleanupSource = notification(listOf(action("Synthetic prior reply", "never-cleaned", listOf(textInput))))
        val priorCleanupOffer = map(cleanupSource)
        val unrelated = map(notification(listOf(action("Unrelated", "unrelated", mutable = false))))
        cleanupSource.notification.category = Notification.CATEGORY_CALL
        // This is the mapper branch NLS selects with Calls Off / Messages On, before invalidation.
        val cleanup = main { requireNotNull(mapper.retireCallIfPreviouslyOffered(cleanupSource)) }
        check(cleanup.retirementOnly && cleanup.retirement == null)
        check(cleanup.envelope.type == PlinkEventType.MessageReceived)
        check(NotificationActionsPolicy.hasValidOffer(cleanup.envelope))
        check(cleanup.envelope.payload["removed"] == JsonPrimitive(true))
        check(cleanup.envelope.payload["actionsCount"] == JsonPrimitive(0))
        check(cleanup.envelope.payload["sender"] == JsonPrimitive("Phone"))
        check(cleanup.envelope.payload["preview"] == JsonPrimitive("Notification removed."))
        check(cleanup.envelope.payload.keys == setOf("sender", "preview", "packageName", "notificationKey", "removed",
            "actionsVersion", "actionsSession", "actionsEpoch", "actionsRevision", "actionsExpiresAtMs", "actionsCount", "actionsOverflowCount"))
        check(main { registry.state() } == null) // Cleanup did not enable action execution.
        producedOffer(cleanup.envelope.encode())
        status(dispatch(enable(unrelated)), "enabled")
        status(dispatch(invoke(priorCleanupOffer, text = "Synthetic stale reply")), "stale_action")
        status(dispatch(invoke(unrelated)), "dispatched"); delivery("unrelated")
        check(main { mapper.retireCallIfPreviouslyOffered(cleanupSource) } == null)
        val neverOffered = notification(emptyList()).also { it.notification.category = Notification.CATEGORY_CALL }
        check(main { mapper.retireCallIfPreviouslyOffered(neverOffered) } == null)
        val disabled = notification(listOf(action("Prior disabled", "never-disabled", mutable = false)))
        map(disabled)
        disabled.notification.category = Notification.CATEGORY_CALL
        main { registry.setFeatureEnabled(false) }
        check(main { mapper.retireCallIfPreviouslyOffered(disabled) } == null)
        main { registry.setFeatureEnabled(true) }
        noDelivery()
        checks += "Calls Off cleanup requires current prior offer and Messages; fixed zero-action retirement does not enable actions or affect other keys"
        main { registry.beginSession("synthetic-phone", "synthetic-mac", generation.sessionGeneration) }
        val exact = "\t  Exact synthetic reply ✓\nCafe\u0301 👩‍💻\n  "
        val offer = map(notification(listOf(action("Archive", "archive", mutable = false),
            action("Mark as read", "read"), action("Reply", "text", listOf(textInput)))))
        check(offer.payload["actionsCount"] == JsonPrimitive(3))
        listOf("Archive", "Mark as read", "Reply").forEachIndexed { i, label ->
            check(offer.payload["action${i}Label"] == JsonPrimitive(label))
        }
        status(dispatch(invoke(offer)), "action_not_enabled"); noDelivery()
        status(dispatch(enable(offer)), "enabled")
        status(dispatch(invoke(offer, 1)), "dispatched"); delivery("read")
        status(dispatch(invoke(offer, 0)), "dispatched"); delivery("archive")
        val textCommand = invoke(offer, 2, exact)
        status(dispatch(textCommand), "dispatched"); delivery("text", exact)
        status(dispatch(textCommand), "stale_action")
        check(runCatching { main { legacyExecutor.execute(legacy(offer, "duplicate"), "synthetic-phone") } }.isFailure)
        noDelivery(); checks += "Source order and selected no-input/text PendingIntents; exact Unicode one field; v1 consumes legacy alias"

        val legacyOffer = map(notification(listOf(action("Reply", "legacy-first", listOf(textInput)))))
        main { legacyExecutor.execute(legacy(legacyOffer, exact), "synthetic-phone") }
        delivery("legacy-first", exact)
        status(dispatch(invoke(legacyOffer, text = exact)), "stale_action"); noDelivery()
        checks += "Legacy dispatch consumes v1 alias"

        val equalLabels = map(notification(listOf(action("Same label", "first"), action("Same label", "second"))))
        status(dispatch(invoke(equalLabels, 1)), "dispatched"); delivery("second")
        status(dispatch(invoke(equalLabels, 0)), "dispatched"); delivery("first"); noDelivery()
        checks += "Equal labels retain distinct action authority"

        val textActions = map(notification(listOf(
            action("Reply to first", "first-text", listOf(RemoteInput.Builder("first-body").build())),
            action("Reply to second", "second-text", listOf(RemoteInput.Builder("second-body").build())))))
        status(dispatch(invoke(textActions, 0)), "invalid_action"); noDelivery()
        status(dispatch(invoke(textActions, 1, "Second exact reply")), "dispatched")
        delivery("second-text", "Second exact reply", "second-body")
        status(dispatch(invoke(textActions, 0, "First exact reply")), "dispatched")
        delivery("first-text", "First exact reply", "first-body"); noDelivery()
        checks += "Multiple text actions keep their own receiver and exact result key; missing input cannot execute"

        val choice = RemoteInput.Builder("choice").setAllowFreeFormInput(false).setChoices(arrayOf("A", "B")).build()
        val data = RemoteInput.Builder("image").setAllowFreeFormInput(false).setAllowDataType("image/png", true).build()
        val secondText = RemoteInput.Builder("second-field").build()
        val unsupported = map(notification(listOf(action("Choice", "never-choice", listOf(choice)),
            action("Photo", "never-photo", listOf(data)), action("Two fields", "never-two", listOf(textInput, secondText)),
            action("Immutable reply", "never-immutable", listOf(textInput), mutable = false))))
        listOf("choice_input", "data_input", "multiple_inputs", "immutable_input").forEachIndexed { i, reason ->
            check(unsupported.payload["action${i}Kind"] == JsonPrimitive("phone"))
            check(unsupported.payload["action${i}Reason"] == JsonPrimitive(reason))
            check("action${i}Token" !in unsupported.payload)
        }
        check(unsupported.payload["canReply"] == JsonPrimitive(false)); noDelivery()
        checks += "Real choice/data/multiple-field/immutable inputs require phone; no invented input"

        val protectedOffer = map(notification(listOf(action("Protected reply", "protected", listOf(textInput), auth = true))))
        check(protectedOffer.payload["action0AuthenticationRequired"] == JsonPrimitive(true))
        check(protectedOffer.payload["canReply"] == JsonPrimitive(false))
        val protectedCommand = invoke(protectedOffer, text = exact)
        unlocked = false; status(dispatch(protectedCommand), "phone_locked"); noDelivery()
        unlocked = null; status(dispatch(protectedCommand), "phone_locked"); noDelivery()
        unlocked = true; status(dispatch(protectedCommand), "dispatched"); delivery("protected", exact)
        check(AndroidNotificationActions.isUserUnlocked(context, UserHandle.getUserHandleForUid(100_000)) == null)
        checks += "Injected locked/unknown state prevents authenticated dispatch; another profile fails closed"

        val canceledAction = action("Canceled", "never-canceled")
        val canceledOffer = map(notification(listOf(canceledAction)))
        canceledAction.actionIntent.cancel()
        status(dispatch(invoke(canceledOffer)), "action_canceled")
        status(dispatch(invoke(canceledOffer)), "stale_action"); noDelivery()
        checks += "Canceled framework PendingIntent reports failure and stays consumed"

        val replacementID = notificationId++
        val old = map(notification(listOf(action("Old", "never-old")), replacementID))
        val currentSbn = notification(listOf(action("New", "new")), replacementID)
        val current = map(currentSbn)
        status(dispatch(invoke(old)), "stale_action")
        status(dispatch(invoke(current)), "dispatched"); delivery("new")
        val removable = notification(listOf(action("Remove", "never-removed")))
        val removedOffer = map(removable)
        producedOffer(main { mapper.removed(removable).envelope.encode() })
        status(dispatch(invoke(removedOffer)), "stale_action"); noDelivery()
        checks += "Actual mapper replacement and tombstone revoke old buttons"

        val snapshotSource = map(notification(listOf(action("Snapshot", "never-snapshot"))))
        val snapshot = main { requireNotNull(registry.captureSnapshot()) }
        clock += 25 // The source existed before reconciliation issues a fresh tombstone.
        val absent = main { registry.removeMissing(snapshot, emptySet()) }
        check(absent.any { it.payload["notificationKey"] == snapshotSource.payload["notificationKey"] })
        absent.forEach { producedOffer(it.encode()) }
        status(dispatch(invoke(snapshotSource)), "stale_action"); noDelivery()
        clock = System.currentTimeMillis()
        checks += "Delayed snapshot reconciliation emits fresh versioned tombstones"

        val bound = map(notification(listOf(action("Bound", "bound"))))
        val boundCommand = invoke(bound)
        status(dispatch(boundCommand.copy(payload = JsonObject(boundCommand.payload + ("text" to JsonPrimitive("not a text action"))))), "invalid_action")
        status(dispatch(boundCommand.copy(payload = JsonObject(boundCommand.payload + ("notificationKey" to JsonPrimitive("other-key"))))), "stale_action")
        status(dispatch(boundCommand.copy(payload = JsonObject(boundCommand.payload + ("actionToken" to JsonPrimitive("00000000-0000-4000-8000-000000000024"))))), "stale_action")
        status(dispatch(boundCommand.copy(sourceDeviceId = "other-peer")), "stale_action")
        status(dispatch(boundCommand.copy(payload = JsonObject(boundCommand.payload + ("sourceEnvelopeId" to JsonPrimitive("other-source"))))), "stale_action")
        status(dispatch(boundCommand.copy(payload = JsonObject(boundCommand.payload + ("packageName" to JsonPrimitive("app.other"))))), "stale_action")
        status(dispatch(boundCommand), "dispatched"); delivery("bound"); noDelivery()
        checks += "Peer, source envelope and package substitution rejected without consuming correct action"

        val expiring = map(notification(listOf(action("Expire", "never-expired"))))
        clock += 600_001
        status(dispatch(invoke(expiring)), "action_expired"); noDelivery()
        clock = System.currentTimeMillis()
        val revoked = map(notification(listOf(action("Revoke", "never-revoked"))))
        main { registry.setListenerAvailable(false) }
        status(dispatch(invoke(revoked)), "actions_disabled"); noDelivery()
        main { registry.setListenerAvailable(true) }
        status(dispatch(invoke(revoked)), "stale_action"); noDelivery()
        val off = map(notification(listOf(action("Off", "never-off"))))
        main { registry.setFeatureEnabled(false) }
        status(dispatch(invoke(off)), "actions_disabled"); noDelivery()
        main { registry.setFeatureEnabled(true) }
        val retired = map(notification(listOf(action("Retire", "never-retired"))))
        main { registry.retireSession() }
        status(dispatch(invoke(retired)), "stale_action"); noDelivery()
        checks += "Expiry, listener lifecycle, feature Off and session retirement reject dispatch"
        return checks
    } finally {
        pending.forEach { runCatching(it::cancel) }
        main { registry.retireSession(); routes.clear(); replies.clear() }
        context.unregisterReceiver(receiver)
    }
}

import Foundation
import PlinkCore
import Testing
import UserNotifications
@testable import PlinkMac

@MainActor
struct NotificationBridgeTests {
    @Test func wifiOnlyCallRemainsReadonlyWithoutHFPOwnership() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var actions = 0
        bridge.onCallAction = { _, _ in actions += 1 }
        bridge.updateCall(MacCallSession(), hfpControlsAvailable: false)
        bridge.show(envelope: call(.callRinging, key: "wifi-only"))
        let id = try #require(notifications.mirrorID)
        let content = try #require(notifications.delivered[id])
        #expect(content.categoryIdentifier == "plink.call.readonly")
        #expect(content.attachments.isEmpty)
        bridge.handleResponse(id: id, action: "call.answer", text: nil)
        #expect(actions == 0)
        bridge.updateCall(MacCallSession(), presentNotification: false, hfpControlsAvailable: false)
        bridge.show(envelope: call(.callRinging, key: "locked-wifi"))
        #expect(notifications.delivered.isEmpty && notifications.pending.isEmpty)
    }

    @Test func blockedIdleHFPAllowsReadonlyMirrorButLockStillRemovesIt() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var hfp = MacCallSession()
        hfp.connected(phoneID: "fixture")
        bridge.updateCall(hfp, hfpControlsAvailable: false)
        bridge.show(envelope: call(.callRinging, key: "blocked-hfp"))
        #expect(notifications.mirror?.categoryIdentifier == "plink.call.readonly")
        bridge.updateCall(hfp, presentNotification: false, hfpControlsAvailable: false)
        bridge.show(envelope: call(.callRinging, key: "locked-hfp"))
        #expect(notifications.delivered.isEmpty && notifications.pending.isEmpty)
    }

    @Test func repeatedSameKeyRingingKeepsOnePresentation() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        bridge.show(envelope: call(.callRinging, key: "same"))
        let id = try #require(notifications.mirrorID)
        bridge.show(envelope: call(.callRinging, key: "same", caller: "Updated"))
        #expect(notifications.mirrorID == id)
        #expect(notifications.submissions == [id])
        #expect(notifications.removals.isEmpty)
    }

    @Test func dismissedReadonlyDoesNotRealertSameLiveIdentity() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        bridge.show(envelope: call(.callRinging, key: "same"))
        let id = try #require(notifications.mirrorID)
        bridge.handleResponse(id: id, action: UNNotificationDismissActionIdentifier, text: nil)
        bridge.show(envelope: call(.callRinging, key: "same"))
        #expect(notifications.submissions == [id])
        #expect(notifications.delivered.isEmpty)
        bridge.show(envelope: call(.callEnded, key: "same"))
        bridge.show(envelope: call(.callRinging, key: "same"))
        #expect(notifications.submissions.count == 2)
    }

    @Test func readyHFPDefersReadonlyForFixedDeadlineAndHandsOver() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var hfp = MacCallSession()
        hfp.connected(phoneID: "AA:BB:CC:DD:EE:FF")
        bridge.updateCall(hfp, selectedPeerID: "app-peer")
        bridge.show(envelope: call(.callRinging, key: "same", peer: "app-peer"))
        let first = try #require(notifications.scheduled.first)
        bridge.show(envelope: call(.callRinging, key: "same", peer: "app-peer"))
        #expect(notifications.scheduled.count == 1)
        #expect(notifications.scheduledDelays == [0.3])
        #expect(notifications.delivered.isEmpty)
        hfp.ringing(number: nil)
        bridge.updateCall(hfp, selectedPeerID: "app-peer")
        first()
        #expect(notifications.mirror == nil)
        #expect(notifications.delivered.values.filter { $0.categoryIdentifier == "plink.call.ringing" }.count == 1)
    }

    @Test func readyHFPWithoutContextFallsBackOnceAtOriginalDeadline() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var hfp = MacCallSession()
        hfp.connected(phoneID: "AA:BB:CC:DD:EE:FF")
        bridge.updateCall(hfp, selectedPeerID: "app-peer")
        bridge.show(envelope: call(.callRinging, key: "same", peer: "app-peer"))
        let first = try #require(notifications.scheduled.first)
        bridge.show(envelope: call(.callRinging, key: "same", peer: "app-peer"))
        #expect(notifications.scheduled.count == 1)
        first()
        let id = try #require(notifications.mirrorID)
        bridge.show(envelope: call(.callRinging, key: "same", peer: "app-peer"))
        #expect(notifications.submissions == [id])
    }

    @Test func graceUsesAuthenticatedPeerIDNotBluetoothAddress() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var hfp = MacCallSession()
        hfp.connected(phoneID: "AA:BB:CC:DD:EE:FF")
        bridge.updateCall(hfp, selectedPeerID: "app-peer")
        bridge.show(envelope: call(.callRinging, key: "wrong-domain", peer: "AA:BB:CC:DD:EE:FF"))
        #expect(notifications.scheduled.isEmpty)
        #expect(notifications.mirror != nil)
        bridge.show(envelope: call(.callRinging, key: "app", peer: "app-peer"))
        #expect(notifications.scheduled.count == 1)
    }

    @Test func sameBluetoothAddressNewAppPeerRetiresPendingFallback() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var hfp = MacCallSession()
        hfp.connected(phoneID: "AA:BB:CC:DD:EE:FF")
        bridge.updateCall(hfp, selectedPeerID: "peer-A")
        bridge.show(envelope: call(.callRinging, key: "A", peer: "peer-A"))
        let oldDeadline = try #require(notifications.scheduled.first)
        bridge.updateCall(hfp, selectedPeerID: "peer-B")
        oldDeadline()
        #expect(notifications.delivered.isEmpty)
        bridge.show(envelope: call(.callRinging, key: "B", peer: "peer-B"))
        #expect(notifications.scheduled.count == 2)
        notifications.scheduled[1]()
        #expect(notifications.mirror != nil)
        #expect(notifications.delivered.count == 1)
    }

    @Test func clearContextsRetiresReadinessWithoutSuppressingReadonlyFallback() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var hfp = MacCallSession()
        hfp.connected(phoneID: "AA:BB:CC:DD:EE:FF")
        bridge.updateCall(hfp, selectedPeerID: "peer-A")
        bridge.show(envelope: call(.callRinging, key: "old", peer: "peer-A"))
        let oldDeadline = try #require(notifications.scheduled.first)
        bridge.clearContexts()
        oldDeadline()
        #expect(notifications.delivered.isEmpty)
        bridge.show(envelope: call(.callRinging, key: "new", peer: "peer-A"))
        #expect(notifications.scheduled.count == 1)
        #expect(notifications.mirror != nil)
    }

    @Test(arguments: ["privacy", "peer", "ended", "clear"])
    func pendingReadonlyCancelsOnLifecycleChange(outcome: String) throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var hfp = MacCallSession()
        hfp.connected(phoneID: "AA:BB:CC:DD:EE:FF")
        bridge.updateCall(hfp, selectedPeerID: "app-peer")
        bridge.show(envelope: call(.callRinging, key: "same", peer: "app-peer"))
        let fire = try #require(notifications.scheduled.first)
        switch outcome {
        case "privacy": bridge.updateCall(hfp, presentNotification: false, selectedPeerID: "app-peer")
        case "peer": hfp.connected(phoneID: "11:22:33:44:55:66"); bridge.updateCall(hfp, selectedPeerID: "other-peer")
        case "ended": bridge.show(envelope: call(.callEnded, key: "same", peer: "app-peer"))
        default: bridge.clearContexts()
        }
        fire()
        #expect(notifications.delivered.isEmpty)
    }

    @Test func unavailableHFPControlsRetainPendingAndUncertainCallAuthority() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var actions = 0
        bridge.onCallAction = { _, _ in actions += 1 }
        var hfp = MacCallSession()
        hfp.connected(phoneID: "fixture")
        hfp.ringing(number: nil)
        bridge.updateCall(hfp)
        let old = try #require(notifications.delivered.keys.first)
        bridge.updateCall(hfp, hfpControlsAvailable: false)
        bridge.handleResponse(id: old, action: "call.answer", text: nil)
        bridge.show(envelope: call(.callRinging, key: "blocked-context"))
        #expect(actions == 0)
        #expect(notifications.delivered.isEmpty && notifications.pending.isEmpty)
        let context = try #require(hfp.context)
        _ = hfp.begin(.answer, context: context)
        bridge.updateCall(hfp, hfpControlsAvailable: false)
        bridge.show(envelope: call(.callRinging, key: "pending-context"))
        hfp.markUnconfirmed(context: context)
        bridge.updateCall(hfp, hfpControlsAvailable: false)
        bridge.show(envelope: call(.callRinging, key: "uncertain-context"))
        #expect(notifications.delivered.isEmpty && notifications.pending.isEmpty)
    }

    @Test func hiddenHFPCallSuppressesNativeAndMirroredCallsButPreservesMessages() {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        bridge.show(envelope: call(.callRinging, key: "mirror-first"))
        var hfp = MacCallSession()
        hfp.connected(phoneID: "synthetic-phone")
        hfp.ringing(number: "synthetic-caller")
        bridge.updateCall(hfp, presentNotification: false)
        bridge.show(envelope: call(.callRinging, key: "mirror-late"))
        #expect(notifications.delivered.isEmpty)
        #expect(notifications.pending.isEmpty)
        if let context = hfp.context { _ = hfp.begin(.answer, context: context) }
        bridge.updateCall(hfp, presentNotification: false)
        bridge.show(envelope: call(.callRinging, key: "while-answering"))
        #expect(notifications.delivered.isEmpty)
        let message = PlinkEnvelope(id: "message", type: .messageReceived, sentAt: Date(), sourceDeviceId: "phone", targetDeviceId: "mac",
            payload: ["sender": .string("Sender"), "preview": .string("Message"), "packageName": .string("test.mail"), "notificationKey": .string("message-key")])
        bridge.show(envelope: message)
        #expect(notifications.delivered.values.contains { $0.body == "Message" })
        hfp.disconnected()
        bridge.updateCall(hfp)
        bridge.show(envelope: call(.callRinging, key: "new-mirror"))
        #expect(notifications.mirror != nil)
    }

    @Test func oldMirroredCallRemovalPreservesReplacementUntilItsOwnRemoval() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        bridge.show(envelope: call(.callRinging, key: "A", caller: "Caller A"))
        let old = try #require(notifications.mirrorID)
        bridge.show(envelope: call(.callRinging, key: "B", caller: "Caller B"))
        let current = try #require(notifications.mirrorID)
        #expect(current != old)
        #expect(notifications.mirror?.body == "Caller B")
        #expect(notifications.delivered.count == 1 && notifications.pending.count == 1)

        bridge.show(envelope: call(.callEnded, key: "A"))
        #expect(notifications.mirror?.body == "Caller B")
        #expect(notifications.pending[current]?.body == "Caller B")
        #expect(notifications.removals == [[old]])

        bridge.show(envelope: call(.callEnded, key: "B"))
        #expect(notifications.delivered.isEmpty)
        #expect(notifications.pending.isEmpty)
        #expect(notifications.removals == [[old], [current]])
    }

    @Test func mirroredRemovalRequiresTheSamePeerAndNotificationKey() {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        bridge.show(envelope: call(.callRinging, key: "same", peer: "phone-A"))
        bridge.show(envelope: call(.callEnded, key: "same", peer: "phone-B"))
        bridge.show(envelope: call(.callEnded, key: nil, peer: "phone-A"))
        #expect(notifications.removals.isEmpty)
        #expect(notifications.mirror != nil)
        bridge.show(envelope: call(.callEnded, key: "same", peer: "phone-A"))
        #expect(notifications.delivered.isEmpty)
    }

    @Test func mirroredCallTombstoneNeverRemovesOrReplacesHFPNotification() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        bridge.show(envelope: call(.callRinging, key: "A"))
        var hfp = MacCallSession()
        hfp.connected(phoneID: "synthetic-phone")
        hfp.ringing(number: "synthetic-caller")
        bridge.updateCall(hfp)
        let id = try #require(notifications.delivered.keys.first { $0.hasPrefix("plink.hfp.") })
        let removedBefore = notifications.removals.count
        bridge.show(envelope: call(.callEnded, key: "A"))
        bridge.show(envelope: call(.callRinging, key: "B"))
        #expect(notifications.delivered[id]?.categoryIdentifier == "plink.call.ringing")
        #expect(notifications.delivered[id]?.subtitle.isEmpty == true)
        #expect(notifications.delivered[id]?.attachments.isEmpty == true)
        #expect(notifications.mirror == nil)
        #expect(notifications.removals.count == removedBefore)
        hfp.setActive(true)
        bridge.updateCall(hfp)
        #expect(notifications.delivered[id] == nil)
        #expect(notifications.delivered.values.contains { $0.categoryIdentifier == "plink.call.active" })
    }

    @Test func clearContextsRemovesKeyedAndUnkeyedMirrorsAndRevokesIdentity() throws {
        let keys: [String?] = ["A", nil]
        for key in keys {
            let notifications = Notifications()
            let bridge = notifications.bridge()
            bridge.show(envelope: call(.callRinging, key: key))
            let id = try #require(notifications.mirrorID)
            bridge.clearContexts()
            #expect(notifications.delivered.isEmpty)
            #expect(notifications.pending.isEmpty)
            #expect(notifications.removals == [[id]])
            bridge.show(envelope: call(.callEnded, key: key))
            #expect(notifications.removals == [[id]])
        }
    }

    @Test func clearContextsPreservesHFPNotificationAndContext() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var hfp = MacCallSession()
        hfp.connected(phoneID: "synthetic-phone")
        hfp.ringing(number: "synthetic-caller")
        bridge.updateCall(hfp)
        let id = try #require(notifications.delivered.keys.first { $0.hasPrefix("plink.hfp.") })
        bridge.clearContexts()
        #expect(notifications.delivered[id]?.categoryIdentifier == "plink.call.ringing")
        #expect(notifications.pending[id]?.categoryIdentifier == "plink.call.ringing")
        bridge.show(envelope: call(.callRinging, key: "B"))
        #expect(notifications.mirror == nil)
        hfp.setActive(true)
        bridge.updateCall(hfp)
        #expect(notifications.delivered[id] == nil)
        #expect(notifications.delivered.values.contains { $0.categoryIdentifier == "plink.call.active" })
    }


    @Test func nativeCategoriesExposeOnlyAuthenticatedHFPControls() throws {
        let categories = NotificationBridge.callCategories
        let ringing = try #require(categories.first { $0.identifier == "plink.call.ringing" })
        #expect(ringing.actions.map(\.identifier) == ["call.answer", "call.decline"])
        #expect(ringing.actions.allSatisfy { $0.options.contains(.authenticationRequired) })
        let active = try #require(categories.first { $0.identifier == "plink.call.active" })
        #expect(active.actions.map(\.identifier) == ["call.hangUp"])
        #expect(active.actions.allSatisfy { $0.options.contains(.authenticationRequired) })
    }

    @Test(arguments: [MacCallAction.answer, .decline, .hangUp])
    func nativeActionsAreCurrentAndOneShot(action: MacCallAction) throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var observed: [MacCallAction] = []
        var hfp = MacCallSession()
        hfp.connected(phoneID: "fixture")
        hfp.ringing(number: "Fixture caller")
        if action == .hangUp { hfp.setActive(true) }
        bridge.onCallAction = { value, context in
            #expect(context == hfp.context)
            observed.append(value)
        }
        bridge.updateCall(hfp)
        let id = try #require(notifications.delivered.keys.first)
        #expect(notifications.delivered[id]?.attachments.isEmpty == true)
        bridge.handleResponse(id: id, action: "call.\(action.rawValue)", text: nil)
        bridge.handleResponse(id: id, action: "call.\(action.rawValue)", text: nil)
        #expect(observed == [action])
        #expect(notifications.delivered.isEmpty && notifications.pending.isEmpty)
        bridge.updateCall(hfp) // An unchanged observation cannot re-enable the consumed action.
        #expect(notifications.delivered.isEmpty)
    }

    @Test func unavailableMacAudioExplainsPhoneAudioWithoutDisablingAnswer() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var actions: [MacCallAction] = []
        bridge.onCallAction = { action, _ in actions.append(action) }
        var hfp = MacCallSession()
        hfp.connected(phoneID: "fixture")
        hfp.ringing(number: nil)
        bridge.updateCall(hfp)
        let old = try #require(notifications.delivered.keys.first)
        let reason = "Mac call audio is unavailable for this connection. Use your phone for audio."
        hfp.markComputerAudioUnsupported()
        bridge.updateCall(hfp, audioUnavailableReason: reason)
        let current = try #require(notifications.delivered.keys.first)
        #expect(current == old)
        #expect(notifications.delivered[current]?.subtitle == reason)
        #expect(notifications.delivered[current]?.categoryIdentifier == "plink.call.ringing")
        #expect(notifications.delivered[current]?.attachments.isEmpty == true)
        bridge.handleResponse(id: current, action: "call.answer", text: nil)
        #expect(actions == [.answer])
    }

    @Test func callerEnrichmentKeepsHFPIdentityAndConsumedAction() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var actions = 0
        bridge.onCallAction = { _, _ in actions += 1 }
        var hfp = MacCallSession()
        hfp.connected(phoneID: "phone")
        hfp.ringing(number: nil)
        bridge.updateCall(hfp)
        let id = try #require(notifications.delivered.keys.first)
        hfp.ringing(number: "Caller")
        bridge.updateCall(hfp)
        #expect(notifications.delivered[id]?.body == "Caller")
        #expect(notifications.delivered[id]?.sound == nil)
        #expect(notifications.submissions == [id, id])
        #expect(notifications.removals.isEmpty)
        bridge.handleResponse(id: id, action: "call.answer", text: nil)
        bridge.updateCall(hfp)
        bridge.handleResponse(id: id, action: "call.answer", text: nil)
        #expect(actions == 1)
        #expect(notifications.delivered.isEmpty)
        #expect(notifications.submissions == [id, id])
    }

    @Test func currentCallBodyClickOpensWithoutCallAction() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var opens = 0
        var actions = 0
        bridge.onOpenNotification = { opens += 1 }
        bridge.onCallAction = { _, _ in actions += 1 }
        bridge.show(envelope: call(.callRinging, key: "mirror"))
        let mirror = try #require(notifications.mirrorID)
        bridge.handleResponse(id: mirror, action: UNNotificationDefaultActionIdentifier, text: nil)
        var hfp = MacCallSession()
        hfp.connected(phoneID: "phone")
        hfp.ringing(number: nil)
        bridge.updateCall(hfp)
        let native = try #require(notifications.delivered.keys.first)
        bridge.handleResponse(id: mirror, action: UNNotificationDefaultActionIdentifier, text: nil)
        bridge.handleResponse(id: native, action: UNNotificationDefaultActionIdentifier, text: nil)
        #expect(opens == 2 && actions == 0)
        bridge.updateCall(hfp, presentNotification: false)
        bridge.handleResponse(id: native, action: UNNotificationDefaultActionIdentifier, text: nil)
        #expect(opens == 2)
    }

    @Test func lockAndUnlockPublishNewIdentityAndRejectOldResponses() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var actions = 0
        bridge.onCallAction = { _, _ in actions += 1 }
        var hfp = MacCallSession()
        hfp.connected(phoneID: "fixture")
        hfp.ringing(number: nil)
        bridge.updateCall(hfp)
        let old = try #require(notifications.delivered.keys.first)
        bridge.updateCall(hfp, presentNotification: false)
        bridge.show(envelope: call(.callRinging, key: "locked-mirror"))
        #expect(notifications.delivered.isEmpty && notifications.pending.isEmpty)
        bridge.handleResponse(id: old, action: "call.answer", text: nil)
        #expect(actions == 0)
        bridge.updateCall(hfp)
        let current = try #require(notifications.delivered.keys.first)
        #expect(current != old)
        bridge.handleResponse(id: old, action: "call.answer", text: nil)
        #expect(actions == 0)
        bridge.handleResponse(id: current, action: "call.answer", text: nil)
        #expect(actions == 1)
    }

    @Test func actionRechecksFreshEligibilityAndAllowedPhase() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var eligible = true
        var eligibilityChecks = 0
        var actions = 0
        bridge.callActionsAllowed = { eligibilityChecks += 1; return eligible }
        bridge.onCallAction = { _, _ in actions += 1 }
        var hfp = MacCallSession()
        hfp.connected(phoneID: "fixture")
        hfp.ringing(number: nil)
        bridge.updateCall(hfp)
        let id = try #require(notifications.delivered.keys.first)
        bridge.handleResponse(id: "retired-fixture", action: "call.answer", text: nil)
        #expect(eligibilityChecks == 0)
        eligible = false // Lock/busy/peer authority changed before its observation arrived.
        bridge.handleResponse(id: id, action: "call.answer", text: nil)
        #expect(eligibilityChecks == 1)
        eligible = true
        bridge.handleResponse(id: id, action: "call.hangUp", text: nil)
        bridge.handleResponse(id: id, action: "call.computerAudio", text: nil)
        #expect(actions == 0)
        #expect(eligibilityChecks == 1)
        bridge.handleResponse(id: id, action: "call.decline", text: nil)
        #expect(actions == 1)
        #expect(eligibilityChecks == 2)
        bridge.handleResponse(id: id, action: "call.decline", text: nil)
        #expect(actions == 1)
        #expect(eligibilityChecks == 2)
    }

    @Test(arguments: ["answering", "uncertain", "waiting", "disconnected", "shutdown", "replacement"])
    func invalidatedCallCannotAcceptOldAction(outcome: String) throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var actions = 0
        bridge.onCallAction = { _, _ in actions += 1 }
        var hfp = MacCallSession()
        hfp.connected(phoneID: "fixture")
        hfp.ringing(number: nil)
        bridge.updateCall(hfp)
        let id = try #require(notifications.delivered.keys.first)
        let context = try #require(hfp.context)
        if outcome == "answering" { _ = hfp.begin(.answer, context: context) }
        if outcome == "uncertain" { hfp.markUnconfirmed(context: context) }
        if outcome == "waiting" { hfp.setActive(true); hfp.ringing(number: "Waiting") }
        if outcome == "disconnected" { hfp.disconnected() }
        if outcome == "replacement" { hfp.connected(phoneID: "replacement"); hfp.ringing(number: nil) }
        if outcome == "shutdown" { bridge.shutdown() } else { bridge.updateCall(hfp) }
        bridge.handleResponse(id: id, action: "call.answer", text: nil)
        #expect(actions == 0)
        #expect(notifications.delivered[id] == nil && notifications.pending[id] == nil)
        if ["answering", "uncertain", "waiting", "shutdown"].contains(outcome) {
            bridge.show(envelope: call(.callRinging, key: "late-mirror"))
            #expect(notifications.mirror == nil)
        }
    }

    @Test func lateNativeDeliveryAfterLockIsRemovedWithoutRemovingReplacement() throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var removals: [[String]] = []
        let bridge = NotificationBridge(removeNotifications: { removals.append($0) },
            addNotification: { requests.append($0); completions.append($1) })
        var hfp = MacCallSession()
        hfp.connected(phoneID: "fixture")
        hfp.ringing(number: nil)
        bridge.updateCall(hfp)
        let old = try #require(requests.first).identifier
        bridge.updateCall(hfp, presentNotification: false)
        completions[0](nil)
        #expect(removals.last == [old])
        bridge.updateCall(hfp)
        let current = try #require(requests.last).identifier
        #expect(current != old)
        completions[0](nil)
        #expect(removals.last == [old])
        completions[1](nil)
        let count = removals.count
        completions[1](nil)
        #expect(removals.count == count)
    }

    @Test func lateMirrorDeliveryCannotDuplicateAuthoritativeNativeCall() throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var removals: [[String]] = []
        let bridge = NotificationBridge(removeNotifications: { removals.append($0) },
            addNotification: { requests.append($0); completions.append($1) })
        bridge.show(envelope: call(.callRinging, key: "mirror"))
        var hfp = MacCallSession()
        hfp.connected(phoneID: "fixture")
        hfp.ringing(number: nil)
        bridge.updateCall(hfp)
        try #require(requests.count == 2 && completions.count == 2)
        #expect(requests[1].content.categoryIdentifier == "plink.call.ringing")
        completions[0](nil)
        #expect(removals.last == [requests[0].identifier])
        #expect(!removals.flatMap { $0 }.contains(requests[1].identifier))
        completions[1](nil)
    }


    @Test(arguments: ["privacy", "clear", "tombstone", "dismiss"])
    func retiredMirrorFinishingAfterUnlockIsRemoved(outcome: String) throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var delivered: Set<String> = []
        let bridge = NotificationBridge(removeNotifications: { ids in delivered.subtract(ids) },
            addNotification: { requests.append($0); completions.append($1) })
        bridge.show(envelope: call(.callRinging, key: "old"))
        let old = try #require(requests.first).identifier
        if outcome == "privacy" { bridge.updateCall(MacCallSession(), presentNotification: false) }
        if outcome == "clear" { bridge.clearContexts() }
        if outcome == "tombstone" { bridge.show(envelope: call(.callEnded, key: "old")) }
        if outcome == "dismiss" { bridge.handleResponse(id: old, action: UNNotificationDismissActionIdentifier, text: nil) }
        bridge.updateCall(MacCallSession(), presentNotification: true)
        // Model the OS add landing after removal, with the original completion still held.
        delivered.insert(old)
        completions[0](nil)
        #expect(delivered.isEmpty)
        #expect(requests.count == 1)
    }

    @Test(arguments: [false, true])
    func lateMirrorCompletionCannotRemoveNewPresentation(lockBeforeReplacement: Bool) throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var delivered: Set<String> = []
        let bridge = NotificationBridge(removeNotifications: { ids in delivered.subtract(ids) },
            addNotification: { requests.append($0); completions.append($1) })
        bridge.show(envelope: call(.callRinging, key: "old"))
        let old = try #require(requests.first).identifier
        if lockBeforeReplacement {
            bridge.updateCall(MacCallSession(), presentNotification: false)
            bridge.updateCall(MacCallSession(), presentNotification: true)
        }
        bridge.show(envelope: call(.callRinging, key: "new"))
        try #require(requests.count == 2)
        let current = requests[1].identifier
        #expect(current != old)
        delivered.insert(current)
        completions[1](nil)
        delivered.insert(old)
        completions[0](nil)
        #expect(delivered == [current])
        completions[1](nil) // Duplicate completion cannot remove the current presentation.
        #expect(delivered == [current])
        bridge.show(envelope: call(.callEnded, key: "old"))
        #expect(delivered == [current])
        bridge.show(envelope: call(.callEnded, key: "new"))
        #expect(delivered.isEmpty)
    }

    private func call(_ type: EventType, key: String?, peer: String = "phone", caller: String = "Caller") -> PlinkEnvelope {
        var payload: [String: PayloadValue] = ["callerName": .string(caller), "packageName": .string("test.dialer")]
        if let key { payload["notificationKey"] = .string(key) }
        return PlinkEnvelope(id: UUID().uuidString, type: type, sentAt: Date(),
            sourceDeviceId: peer, targetDeviceId: "mac", payload: payload)
    }

    /// Only the OS delivery boundary is replaced; identity decisions run in NotificationBridge.
    @MainActor
    private final class Notifications {
        var delivered: [String: UNNotificationContent] = [:]
        var pending: [String: UNNotificationContent] = [:]
        var removals: [[String]] = []
        var submissions: [String] = []
        var scheduled: [@MainActor () -> Void] = []
        var scheduledDelays: [TimeInterval] = []
        var mirrorID: String? { delivered.keys.first { $0.hasPrefix("plink.call.mirrored.") } }
        var mirror: UNNotificationContent? { mirrorID.flatMap { delivered[$0] } }

        func bridge() -> NotificationBridge {
            NotificationBridge(submitNotification: { request in
                self.submissions.append(request.identifier)
                self.delivered[request.identifier] = request.content
                self.pending[request.identifier] = request.content
            }, removeNotifications: { ids in
                self.removals.append(ids)
                for id in ids {
                    self.delivered.removeValue(forKey: id)
                    self.pending.removeValue(forKey: id)
                }
            }, schedule: { delay, fire in self.scheduledDelays.append(delay); self.scheduled.append(fire) })
        }
    }
}

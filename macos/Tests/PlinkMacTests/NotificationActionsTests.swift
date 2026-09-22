import Foundation
import PlinkCore
import Testing
import UserNotifications
@testable import PlinkMac

@MainActor
struct NotificationActionsTests {
    @Test func malformedActionExtensionPreservesTextWithoutLegacyAuthority() {
        var requests: [UNNotificationRequest] = []
        var replies = 0
        let bridge = NotificationBridge(submitNotification: { requests.append($0) }, removeNotifications: { _ in })
        bridge.onTextReply = { _, _ in replies += 1 }
        let envelope = PlinkEnvelope(id: "offer", type: .messageReceived, sentAt: .now,
            sourceDeviceId: "phone", targetDeviceId: "mac", payload: [
                "sender": .string("Sender"), "preview": .string("Preview"),
                "packageName": .string("test.chat"), "notificationKey": .string("key"),
                "canReply": .bool(true), "replyToken": .string("legacy-token"),
                "actionsVersion": .int(1), "actionsCount": .int(1)])
        bridge.show(envelope: envelope)
        #expect(requests.count == 1)
        #expect(requests.first?.content.body == "Preview")
        #expect(requests.first?.content.categoryIdentifier == "plink.message.readonly")
        if let id = requests.first?.identifier { bridge.handleResponse(id: id, action: "message.reply", text: "Synthetic") }
        #expect(replies == 0)
    }

    @Test func actionCapabilityFieldsAreRedacted() {
        let envelope = PlinkEnvelope(id: "offer", type: .messageReceived, sentAt: .now,
            sourceDeviceId: "phone", targetDeviceId: "mac", payload: [
                "actionsSession": .string("11111111-1111-4111-8111-111111111111"),
                "action0Token": .string("22222222-2222-4222-8222-222222222222"),
                "action0Label": .string("Private label"), "replyToken": .string("legacy-secret")])
        let redacted = PayloadPolicy.redact(envelope)
        for key in envelope.payload.keys { #expect(redacted.payload[key] == .string("[redacted]")) }
    }

    @Test func contractedActionEventTypesAreDecodable() {
        for type in ["notification.actions.enable", "notification.actions.state", "notification.action"] {
            #expect(EventType(rawValue: type) != nil)
        }
    }
}

private let actionTestSession = "12345678-1234-4123-8123-123456789abc"
private let actionTestToken = "87654321-4321-4321-8321-cba987654321"
private let actionTestNow = Date(timeIntervalSince1970: 1_800_000_000)

private func actionOffer(revision: Int, key: String = "key", epoch: Int = 1,
                         count: Int = 1, kind: String = "invoke", label: String = "Archive",
                         now: Date = actionTestNow, removed: Bool = false) -> PlinkEnvelope {
    var payload: [String: PayloadValue] = ["sender": .string("Synthetic sender"), "preview": .string("Synthetic preview"),
        "packageName": .string("test.chat"), "notificationKey": .string(key),
        "actionsVersion": .int(1), "actionsSession": .string(actionTestSession), "actionsEpoch": .int(epoch),
        "actionsRevision": .int(revision), "actionsExpiresAtMs": .int(Int(now.timeIntervalSince1970 * 1000) + 600_000),
        "actionsCount": .int(count), "actionsOverflowCount": .int(0), "removed": .bool(removed)]
    for index in 0..<count {
        let prefix = "action\(index)"
        payload[prefix + "Label"] = .string(label)
        payload[prefix + "Kind"] = .string(kind)
        payload[prefix + "AuthenticationRequired"] = .bool(false)
        if kind == "phone" { payload[prefix + "Reason"] = .string("multiple_inputs") }
        else { payload[prefix + "Token"] = .string(index == 0 ? actionTestToken : UUID().uuidString.lowercased()) }
        if kind == "text" { payload[prefix + "InputLabel"] = .string("Your answer") }
    }
    return PlinkEnvelope(id: "offer-\(revision)-\(key)", type: .messageReceived, sentAt: now,
        sourceDeviceId: "phone", targetDeviceId: "mac", payload: payload)
}

@MainActor
private final class ActionHarness {
    var bridge: NotificationBridge!
    var requests: [UNNotificationRequest] = []
    var completions: [(@MainActor (Error?) -> Void)] = []
    var removed: [String] = []
    var categories: Set<UNNotificationCategory> = []
    var registeredBeforeAdd = true
    var commands: [PlinkEnvelope] = []
    var info: [String] = []
    var stale = 0
    var allowed = true
    var clock = actionTestNow
    let generation = UUID()
    init() {
        bridge = NotificationBridge(removeNotifications: { [unowned self] in removed += $0 },
            addNotification: { [unowned self] request, completion in
                if request.content.categoryIdentifier.hasPrefix("plink.actions.") {
                    registeredBeforeAdd = registeredBeforeAdd && categories.contains { $0.identifier == request.content.categoryIdentifier }
                }
                requests.append(request); completions.append(completion)
            }, registerCategories: { [unowned self] in categories = $0 }, now: { [unowned self] in clock })
        bridge.onNotificationAction = { [unowned self] envelope, _ in commands.append(envelope) }
        bridge.onActionInfo = { [unowned self] in info.append($0) }
        bridge.onStaleAction = { [unowned self] in stale += 1 }
        bridge.notificationActionsAllowed = { [unowned self] in allowed && $0 == generation }
        bridge.bindActionAdmission(localID: "mac", peerID: "phone", generation: generation)
    }
    func negotiate() throws {
        bridge.show(envelope: actionOffer(revision: 1))
        let enable = try #require(commands.first)
        _ = bridge.handleActionControl(outcome(enable, status: "enabled"))
    }
    func outcome(_ command: PlinkEnvelope, status: String = "dispatched", error: String? = nil) -> PlinkEnvelope {
        var payload: [String: PayloadValue] = ["eventId": .string(command.id), "action": .string(command.type.rawValue),
            "actionsVersion": .int(1), "actionsSession": .string(actionTestSession)]
        if let error { payload["code"] = .string(error) }
        else {
            payload["status"] = .string(status)
            if command.type == .notificationActionsEnable { payload["actionsEpoch"] = .int(1) }
        }
        return PlinkEnvelope(id: "result", type: error == nil ? .ack : .error, sentAt: clock,
            sourceDeviceId: "phone", targetDeviceId: "mac", payload: payload)
    }
    func click(_ request: UNNotificationRequest, index: Int = 0, text: String? = nil, category: String? = nil) {
        bridge.handleResponse(id: request.identifier, action: "notification.action.\(index)", text: text,
                              category: category ?? request.content.categoryIdentifier)
    }
}

extension NotificationActionsTests {
    @Test func offerNegotiationIsOnceAndRequiresExactAcknowledgment() throws {
        let h = ActionHarness()
        h.bridge.show(envelope: actionOffer(revision: 1))
        let first = try #require(h.requests.last)
        #expect(first.content.categoryIdentifier == "plink.message.readonly")
        h.bridge.show(envelope: actionOffer(revision: 2))
        #expect(h.commands.count == 1)
        let enable = try #require(h.commands.first)
        var wrong = h.outcome(enable, status: "enabled")
        wrong.payload["actionsSession"] = .string("11111111-1111-4111-8111-111111111111")
        _ = h.bridge.handleActionControl(wrong)
        h.bridge.show(envelope: actionOffer(revision: 3))
        #expect(h.requests.last?.content.categoryIdentifier == "plink.message.readonly")
        _ = h.bridge.handleActionControl(h.outcome(enable, status: "enabled"))
        h.bridge.show(envelope: actionOffer(revision: 4))
        #expect(h.requests.last?.content.categoryIdentifier.hasPrefix("plink.actions.") == true)
        h.click(first)
        #expect(h.commands.count == 1)
    }

    @Test func exactNativeLabelsOptionsAllTenSlotsAndCallCategories() throws {
        let h = ActionHarness(); try h.negotiate()
        var offer = actionOffer(revision: 2, count: 10, kind: "text", label: "Répondre ✓")
        offer.payload["action0AuthenticationRequired"] = .bool(true)
        offer.payload["action1Destructive"] = .bool(true)
        h.bridge.show(envelope: offer)
        let request = try #require(h.requests.last)
        let category = try #require(h.categories.first { $0.identifier == request.content.categoryIdentifier })
        #expect(category.actions.count == 10)
        #expect(category.actions.map(\.title) == Array(repeating: "Répondre ✓", count: 10))
        #expect(category.actions[0].options.contains(.authenticationRequired))
        #expect(category.actions[1].options.contains(.destructive))
        #expect((category.actions[0] as? UNTextInputNotificationAction)?.textInputPlaceholder == "Your answer")
        #expect(h.categories.contains { $0.identifier == "plink.call.ringing" })
        #expect(h.categories.contains { $0.identifier == "plink.call.active" })
        #expect(h.registeredBeforeAdd)
        let text = "\t  Exact reply ✓\nCafe\u{301} 👩‍💻\n  "
        h.click(request, text: text)
        h.click(request, text: text)
        h.click(request, index: 1, text: "Second")
        #expect(h.commands.count == 3) // Enable, then two independent slots, never duplicate slot zero.
        #expect(h.commands[1].payload["text"] == .string(text))
        #expect(h.commands[1].payload["actionToken"] == offer.payload["action0Token"])
        #expect(h.commands[2].payload["actionIndex"] == .int(1))
    }

    @Test func categoryMismatchLockPhoneOnlyAndDefaultTapNeverInvoke() throws {
        let h = ActionHarness(); try h.negotiate()
        h.bridge.show(envelope: actionOffer(revision: 2))
        let request = try #require(h.requests.last)
        h.click(request, category: "wrong")
        h.allowed = false; h.click(request); h.allowed = true
        h.bridge.handleResponse(id: request.identifier, action: UNNotificationDefaultActionIdentifier, text: nil)
        var phone = actionOffer(revision: 3, kind: "phone")
        phone.payload["actionsOverflowCount"] = .int(3)
        h.bridge.show(envelope: phone)
        h.click(try #require(h.requests.last))
        #expect(h.commands.count == 1)
        #expect(h.info.contains { $0.contains("3 more actions") })
        #expect(h.info.last == "Complete the requested fields on your phone.")
    }

    @Test func updateTombstoneExpiryAndAdmissionReplacementRetireButtons() throws {
        let h = ActionHarness(); try h.negotiate()
        h.bridge.show(envelope: actionOffer(revision: 2))
        let old = try #require(h.requests.last)
        h.bridge.show(envelope: actionOffer(revision: 4, count: 0, removed: true))
        let count = h.requests.count
        h.bridge.show(envelope: actionOffer(revision: 3))
        #expect(h.requests.count == count)
        h.click(old)
        h.bridge.show(envelope: actionOffer(revision: 5))
        let expiring = try #require(h.requests.last)
        h.clock = actionTestNow.addingTimeInterval(600)
        h.click(expiring); h.bridge.expireContexts()
        #expect(h.removed.contains(expiring.identifier))
        h.clock = actionTestNow
        h.bridge.show(envelope: actionOffer(revision: 6))
        let prior = try #require(h.requests.last)
        h.bridge.bindActionAdmission(localID: "mac", peerID: "other", generation: UUID())
        h.click(prior)
        #expect(h.commands.count == 1)
    }

    @Test func epochDisableAndLateOldStateCannotRestoreAuthority() throws {
        let h = ActionHarness(); try h.negotiate()
        h.bridge.show(envelope: actionOffer(revision: 2))
        let old = try #require(h.requests.last)
        var state = PlinkEnvelope(id: "state", type: .notificationActionsState, sentAt: h.clock,
            sourceDeviceId: "phone", targetDeviceId: "mac", payload: ["actionsVersion": .int(1),
                "actionsSession": .string(actionTestSession), "actionsEpoch": .int(2), "state": .string("disabled")])
        _ = h.bridge.handleActionControl(state)
        h.click(old)
        h.bridge.show(envelope: actionOffer(revision: 3, epoch: 2))
        #expect(h.requests.last?.content.categoryIdentifier == "plink.message.readonly")
        state.payload["actionsEpoch"] = .int(1); state.payload["state"] = .string("enabled")
        _ = h.bridge.handleActionControl(state)
        h.bridge.show(envelope: actionOffer(revision: 4, epoch: 2))
        #expect(h.requests.last?.content.categoryIdentifier == "plink.message.readonly")
        #expect(h.commands.count == 1)
    }

    @Test func lostOutcomeNeverRetriesAndWrongOutcomeCannotConsumePending() throws {
        let h = ActionHarness(); try h.negotiate()
        h.bridge.show(envelope: actionOffer(revision: 2, count: 2))
        let request = try #require(h.requests.last)
        h.click(request)
        let command = try #require(h.commands.last)
        var wrong = h.outcome(command, error: "phone_locked")
        wrong.payload["action"] = .string("message.reply")
        _ = h.bridge.handleActionControl(wrong)
        #expect(h.info.last == "Waiting for your phone…")
        _ = h.bridge.handleActionControl(h.outcome(command, error: "phone_locked"))
        #expect(h.info.last == "Unlock your phone.")
        h.click(request, index: 1)
        let pending = try #require(h.commands.last)
        h.clock = h.clock.addingTimeInterval(30)
        _ = h.bridge.handleActionControl(h.outcome(pending))
        #expect(h.info.last == "Waiting for your phone…")
        h.bridge.expireContexts()
        #expect(h.info.last == "Could not confirm the action.")
        h.click(request, index: 1)
        #expect(h.commands.count == 3)
    }

    @Test func heldAddsAfterDismissOrReplacementCannotRestoreOrRemoveCurrentButtons() throws {
        let h = ActionHarness(); try h.negotiate()
        h.bridge.show(envelope: actionOffer(revision: 2))
        let old = try #require(h.requests.last)
        let completion = try #require(h.completions.last)
        h.bridge.show(envelope: actionOffer(revision: 3))
        let current = try #require(h.requests.last)
        completion(nil)
        #expect(h.removed.contains(old.identifier))
        #expect(!h.removed.contains(current.identifier))
        h.click(old); h.click(current)
        #expect(h.commands.count == 2)
        let latestCompletion = try #require(h.completions.last)
        h.bridge.handleResponse(id: current.identifier, action: UNNotificationDismissActionIdentifier, text: nil)
        latestCompletion(nil)
        h.click(current)
        #expect(h.commands.count == 2)
        #expect(h.removed.filter { $0 == current.identifier }.count >= 2)
    }

    @Test func categoryAndWatermarkCapacityRejectEvictedReplayWithoutLosingNewerActions() throws {
        let h = ActionHarness(); try h.negotiate()
        var first: UNNotificationRequest?
        for revision in 2...131 {
            h.bridge.show(envelope: actionOffer(revision: revision, key: "key-\(revision)", label: "Action \(revision)"))
            if revision == 2 { first = h.requests.last }
            #expect(h.categories.filter { $0.identifier.hasPrefix("plink.actions.") }.count <= 128)
        }
        let latest = try #require(h.requests.last)
        let count = h.requests.count
        h.bridge.show(envelope: actionOffer(revision: 2, key: "key-2"))
        #expect(h.requests.count == count)
        h.click(try #require(first)); h.click(latest)
        #expect(h.commands.count == 2)
        let firstRequest = try #require(first)
        #expect(h.removed.contains(firstRequest.identifier))
    }
}

extension NotificationActionsTests {
    @Test func retiredPresentationStillAcceptsItsBoundedDispatchOutcome() throws {
        for retirement in ["update", "remove", "dismiss"] {
            let h = ActionHarness(); try h.negotiate()
            h.bridge.show(envelope: actionOffer(revision: 2, count: 2))
            let original = try #require(h.requests.last)
            let heldAdd = try #require(h.completions.last)
            h.click(original)
            let command = try #require(h.commands.last)
            if retirement == "dismiss" {
                h.bridge.handleResponse(id: original.identifier, action: UNNotificationDismissActionIdentifier, text: nil)
            } else {
                h.bridge.show(envelope: actionOffer(revision: 3, count: retirement == "remove" ? 0 : 1,
                                                   removed: retirement == "remove"))
            }
            #expect(h.info.last == "Waiting for your phone…")
            let requestCount = h.requests.count
            heldAdd(nil)
            h.click(original, index: 1)
            _ = h.bridge.handleActionControl(h.outcome(command))
            #expect(h.info.last == "Phone accepted the action. Delivery is not confirmed.")
            #expect(h.commands.count == 2)
            #expect(h.requests.count == requestCount)
            #expect(h.removed.contains(original.identifier))
            h.clock = h.clock.addingTimeInterval(30)
            h.bridge.expireContexts()
            #expect(h.info.last == "Phone accepted the action. Delivery is not confirmed.")
        }
    }

    @Test func removedPresentationWithoutOutcomeStillTimesOut() throws {
        let h = ActionHarness(); try h.negotiate()
        h.bridge.show(envelope: actionOffer(revision: 2))
        h.click(try #require(h.requests.last))
        let command = try #require(h.commands.last)
        h.bridge.show(envelope: actionOffer(revision: 3, count: 0, removed: true))
        h.clock = actionTestNow.addingTimeInterval(29)
        h.bridge.expireContexts()
        #expect(h.info.last == "Waiting for your phone…")
        h.clock = actionTestNow.addingTimeInterval(30)
        h.bridge.expireContexts()
        #expect(h.info.last == "Could not confirm the action.")
        _ = h.bridge.handleActionControl(h.outcome(command))
        #expect(h.info.last == "Could not confirm the action.")
        #expect(h.commands.count == 2)
    }

    @Test func retiredAttemptCannotOverwriteNewerAttemptByAnyCompletionPath() throws {
        for completion in ["ack", "error", "failure", "timeout"] {
            let h = ActionHarness(); try h.negotiate()
            h.bridge.show(envelope: actionOffer(revision: 2))
            h.click(try #require(h.requests.last))
            let first = try #require(h.commands.last)
            h.clock = actionTestNow.addingTimeInterval(5)
            h.bridge.show(envelope: actionOffer(revision: 3))
            let replacement = try #require(h.requests.last)
            h.click(replacement)
            let second = try #require(h.commands.last)
            switch completion {
            case "ack": _ = h.bridge.handleActionControl(h.outcome(first))
            case "error": _ = h.bridge.handleActionControl(h.outcome(first, error: "phone_locked"))
            case "failure": h.bridge.actionTransportFailed(first.id, generation: h.generation)
            default:
                h.clock = actionTestNow.addingTimeInterval(30)
                h.bridge.expireContexts()
            }
            #expect(h.info.last == "Waiting for your phone…")
            #expect(!h.removed.contains(replacement.identifier))
            _ = h.bridge.handleActionControl(h.outcome(second))
            #expect(h.info.last == "Phone accepted the action. Delivery is not confirmed.")
            #expect(h.commands.count == 3)
        }
    }

    @Test func globalRetirementEndsWaitingOnceAndRejectsLateResults() throws {
        for retirement in ["peer", "clear", "disabled", "epoch"] {
            let h = ActionHarness(); try h.negotiate()
            h.bridge.show(envelope: actionOffer(revision: 2))
            let original = try #require(h.requests.last)
            h.click(original)
            let command = try #require(h.commands.last)
            switch retirement {
            case "peer": h.bridge.bindActionAdmission(localID: "mac", peerID: "other", generation: UUID())
            case "clear": h.bridge.clearContexts()
            case "disabled":
                let state = PlinkEnvelope(id: "off", type: .notificationActionsState, sentAt: h.clock,
                    sourceDeviceId: "phone", targetDeviceId: "mac", payload: ["actionsVersion": .int(1),
                        "actionsSession": .string(actionTestSession), "actionsEpoch": .int(2), "state": .string("disabled")])
                _ = h.bridge.handleActionControl(state)
            default: h.bridge.show(envelope: actionOffer(revision: 3, epoch: 2))
            }
            #expect(h.info.last == "Could not confirm the action.")
            let statusCount = h.info.count
            _ = h.bridge.handleActionControl(h.outcome(command))
            h.bridge.actionTransportFailed(command.id, generation: h.generation)
            h.clock = actionTestNow.addingTimeInterval(30); h.bridge.expireContexts()
            h.click(original)
            #expect(h.info.count == statusCount)
            #expect(h.commands.count == 2)
        }
    }

    @Test func transportFailureAfterRemovalSettlesWithoutRecreatingPresentation() throws {
        let h = ActionHarness(); try h.negotiate()
        h.bridge.show(envelope: actionOffer(revision: 2))
        h.click(try #require(h.requests.last))
        let command = try #require(h.commands.last)
        h.bridge.show(envelope: actionOffer(revision: 3, count: 0, removed: true))
        let count = h.requests.count
        h.bridge.actionTransportFailed(command.id, generation: h.generation)
        #expect(h.info.last == "Could not confirm the action.")
        #expect(h.requests.count == count)
        #expect(h.commands.count == 2)
    }
}

// Independently written durable wire preview: no replyToken or actions*/actionN* fields,
// and canReply=false, matching DurableEventOutbox's sanitizer without calling it.
private func durableActionPreview(id: String = "durable-A", key: String = "key",
                                  package: String = "test.chat", peer: String = "phone",
                                  target: String = "mac", removed: Bool = false) -> PlinkEnvelope {
    PlinkEnvelope(id: id, type: .messageReceived, sentAt: actionTestNow,
        sourceDeviceId: peer, targetDeviceId: target, payload: [
            "sender": .string("Synthetic sender"), "preview": .string("Older durable preview"),
            "packageName": .string(package), "notificationKey": .string(key),
            "canReply": .bool(false), "removed": .bool(removed)])
}

extension NotificationActionsTests {
    @Test func durablePreviewAndTombstoneCannotRetireObservedV1OrItsPendingOutcome() throws {
        let h = ActionHarness(); try h.negotiate()
        h.bridge.show(envelope: actionOffer(revision: 2, count: 2))
        let current = try #require(h.requests.last)
        h.click(current)
        let firstCommand = try #require(h.commands.last)
        let count = h.requests.count
        h.bridge.show(envelope: durableActionPreview())
        h.bridge.show(envelope: durableActionPreview(id: "durable-tombstone", removed: true))
        #expect(h.requests.count == count)
        #expect(!h.removed.contains(current.identifier))
        _ = h.bridge.handleActionControl(h.outcome(firstCommand))
        #expect(h.info.last == "Phone accepted the action. Delivery is not confirmed.")
        h.click(current, index: 1)
        #expect(h.commands.count == 3)
        h.bridge.show(envelope: actionOffer(revision: 3, count: 0, removed: true))
        #expect(h.removed.contains(current.identifier))
        h.click(current)
        #expect(h.commands.count == 3)
    }

    @Test func missingMetadataGuardBeginsAtObservationAndResetsWithAdmission() throws {
        let h = ActionHarness()
        h.bridge.show(envelope: actionOffer(revision: 1)) // Negotiation still pending.
        let count = h.requests.count
        h.bridge.show(envelope: durableActionPreview())
        #expect(h.requests.count == count)
        h.bridge.show(envelope: durableActionPreview(id: "legacy-other", key: "never-v1"))
        let other = try #require(h.requests.last)
        #expect(h.requests.count == count + 1)
        h.bridge.show(envelope: durableActionPreview(id: "legacy-other-remove", key: "never-v1", removed: true))
        #expect(h.removed.contains(other.identifier))
        h.bridge.bindActionAdmission(localID: "mac", peerID: "phone", generation: UUID())
        h.bridge.show(envelope: durableActionPreview(id: "legacy-new-admission"))
        #expect(h.requests.count == count + 2)
        #expect(h.requests.last?.content.body == "Older durable preview")
    }

    @Test func guardUsesExactIdentityAndMalformedPresentExtensionRemainsReadonly() throws {
        for variant in ["package", "peer", "target", "malformed"] {
            let h = ActionHarness(); try h.negotiate()
            h.bridge.show(envelope: actionOffer(revision: 2))
            var envelope = durableActionPreview(id: "distinct-\(variant)",
                package: variant == "package" ? "other.package" : "test.chat",
                peer: variant == "peer" ? "other-phone" : "phone", target: variant == "target" ? "other-mac" : "mac")
            if variant == "malformed" {
                envelope.payload["actionsVersion"] = .int(1)
                envelope.payload["actionsCount"] = .int(1)
                envelope.payload["canReply"] = .bool(true)
                envelope.payload["replyToken"] = .string("synthetic-legacy-token")
            }
            let count = h.requests.count
            h.bridge.show(envelope: envelope)
            #expect(h.requests.count == count + 1)
            #expect(h.requests.last?.content.categoryIdentifier == "plink.message.readonly")
            #expect(h.commands.count == 1)
        }
    }
}

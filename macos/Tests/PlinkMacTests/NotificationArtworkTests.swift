import Foundation
import PlinkCore
import Testing
import UserNotifications
@testable import PlinkMac

@MainActor
struct NotificationArtworkTests {
    @Test func displayLabelsRemoveControlsAndBoundScalars() {
        #expect(NotificationArtwork.subtitle(appName: "Cha\nt\u{202E}", phoneName: "My\tPhone") == "Chat · MyPhone")
        #expect(NotificationArtwork.subtitle(appName: "\n", phoneName: nil) == "Phone")
        let label = NotificationArtwork.label(String(repeating: "😀", count: 100))
        #expect(label.unicodeScalars.count == 80)
    }

    @Test(arguments: ["malformed", ""])
    func ignoredOptionalArtworkDoesNotDropOrRerouteMessage(icon: String) {
        var requests: [UNNotificationRequest] = []
        let bridge = NotificationBridge(submitNotification: { requests.append($0) }, removeNotifications: { _ in })
        let envelope = message(icon: icon)
        bridge.show(envelope: envelope, pairedPhoneName: "Trusted phone")
        #expect(requests.count == 1)
        #expect(requests.first?.identifier == "plink.message-\(envelope.id)")
        #expect(requests.first?.content.title == "Sender")
        #expect(requests.first?.content.body == "Preview")
        #expect(requests.first?.content.subtitle == "Chat · Trusted phone")
        #expect(requests.first?.content.categoryIdentifier == "plink.message.readonly")
        #expect(requests.first?.content.attachments.isEmpty == true)
    }

    @Test(arguments: ["failure", "tombstone", "pair-switch", "replacement", "dismiss", "reply", "shutdown"])
    func deliveryFailureAffectsOnlyCurrentNotification(outcome: String) throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var replies: [ReplyContext] = []
        var errors = 0
        let bridge = NotificationBridge(removeNotifications: { _ in },
            addNotification: { request, callback in requests.append(request); completions.append(callback) })
        bridge.onDeliveryError = { _, _ in errors += 1 }
        bridge.onTextReply = { context, _ in replies.append(context) }
        let envelope = message(icon: "ignored", canReply: true)
        bridge.show(envelope: envelope, pairedPhoneName: "Trusted phone")
        let request = try #require(requests.first)
        #expect(request.content.attachments.isEmpty)
        let id = request.identifier
        if outcome == "pair-switch" { bridge.clearContexts() }
        if outcome == "shutdown" { bridge.shutdown() }
        if outcome == "tombstone" {
            bridge.show(envelope: PlinkEnvelope(id: UUID().uuidString, type: .messageReceived, sentAt: Date(),
                sourceDeviceId: "phone", targetDeviceId: "mac", payload: [
                    "notificationKey": .string("fixture-key"), "removed": .bool(true)]))
        }
        if outcome == "replacement" { bridge.show(envelope: message(icon: "ignored", canReply: true)) }
        if outcome == "dismiss" {
            bridge.handleResponse(id: id, action: UNNotificationDismissActionIdentifier, text: nil)
        }
        if outcome == "reply" {
            bridge.handleResponse(id: id, action: "message.reply", text: "Fixture reply")
            bridge.handleResponse(id: id, action: "message.reply", text: "Duplicate")
            #expect(replies.count == 1)
            #expect(replies.first?.pairedDeviceId == "phone")
            #expect(replies.first?.packageName == "test.chat")
            #expect(replies.first?.replyToken == "synthetic-token")
        }
        let before = requests.count
        let completion = try #require(completions.first)
        completion(CocoaError(.fileReadCorruptFile))
        #expect(requests.count == before) // Ordinary failures never retry.
        #expect(errors == (outcome == "failure" ? 1 : 0))
        if outcome == "failure" {
            bridge.handleResponse(id: id, action: "message.reply", text: "Too late")
            #expect(replies.isEmpty)
        }
        if outcome == "replacement" {
            let replacement = try #require(requests.last)
            bridge.handleResponse(id: replacement.identifier, action: "message.reply", text: "Fixture reply")
            #expect(replies.count == 1)
        }
    }

    @Test func staleDeliveryFailureCannotEvictSameIDReplacement() throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var errors = 0
        var replies: [ReplyContext] = []
        let bridge = NotificationBridge(removeNotifications: { _ in },
            addNotification: { request, callback in requests.append(request); completions.append(callback) })
        bridge.onDeliveryError = { _, _ in errors += 1 }
        bridge.onTextReply = { context, _ in replies.append(context) }
        let envelope = message(icon: "ignored", canReply: true)
        bridge.show(envelope: envelope)
        let replacement = PlinkEnvelope(id: envelope.id, type: .messageReceived, sentAt: Date(),
            sourceDeviceId: "phone", targetDeviceId: "mac", payload: envelope.payload.merging([
                "replyToken": .string("replacement-token")]) { _, new in new })
        bridge.show(envelope: replacement)
        try #require(requests.count == 2 && completions.count == 2)
        #expect(requests[1].identifier == requests[0].identifier)
        completions[0](CocoaError(.fileReadCorruptFile))
        #expect(errors == 0)
        #expect(requests.count == 2)
        completions[1](nil)
        completions[1](CocoaError(.fileReadCorruptFile)) // Duplicate callback is no longer owned.
        #expect(errors == 0)
        bridge.handleResponse(id: requests[1].identifier, action: "message.reply", text: "Fixture reply")
        #expect(replies.count == 1)
        #expect(replies.first?.replyToken == "replacement-token")
    }

    @Test func dismissRemovesPendingAndDeliveredAndIgnoresLateFailure() throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var removals: [[String]] = []
        var errors = 0
        var replies = 0
        let bridge = NotificationBridge(removeNotifications: { removals.append($0) },
            addNotification: { request, callback in requests.append(request); completions.append(callback) })
        bridge.onDeliveryError = { _, _ in errors += 1 }
        bridge.onTextReply = { _, _ in replies += 1 }
        bridge.show(envelope: message(icon: "ignored", canReply: true))
        let id = try #require(requests.first).identifier
        bridge.handleResponse(id: id, action: UNNotificationDismissActionIdentifier, text: nil)
        #expect(removals == [[id]]) // Shared pending-and-delivered removal boundary.
        let completion = try #require(completions.first)
        completion(CocoaError(.fileReadCorruptFile))
        #expect(errors == 0)
        #expect(requests.count == 1)
        bridge.handleResponse(id: id, action: "message.reply", text: "Too late")
        #expect(replies == 0)
    }

    private func message(icon: String, canReply: Bool = false) -> PlinkEnvelope {
        PlinkEnvelope(id: UUID().uuidString, type: .messageReceived, sentAt: Date(),
            sourceDeviceId: "phone", targetDeviceId: "mac", payload: [
                "notificationKey": .string("fixture-key"), "sender": .string("Sender"),
                "preview": .string("Preview"), "sourceAppName": .string("Chat"),
                "canReply": .bool(canReply), "packageName": .string("test.chat"), "replyToken": .string("synthetic-token"),
                "sourceAppIconPng": .string(icon), "phoneName": .string("Untrusted name")])
    }

}

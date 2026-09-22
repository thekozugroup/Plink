import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
        let envelope = message(icon: try png().base64EncodedString(), canReply: true)
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
        if outcome == "replacement" { bridge.show(envelope: message(icon: try png().base64EncodedString(), canReply: true)) }
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

    @Test(arguments: ["replacement", "tombstone", "clear", "dismiss", "reply", "shutdown"])
    func retiredMessageLateSuccessCannotResurrect(outcome: String) throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var delivered: Set<String> = []
        var replies: [ReplyContext] = []
        let bridge = NotificationBridge(removeNotifications: { delivered.subtract($0) },
            addNotification: { requests.append($0); completions.append($1) })
        bridge.onTextReply = { context, _ in replies.append(context) }
        bridge.show(envelope: message(icon: "", canReply: true))
        let old = try #require(requests.first).identifier
        var expected: Set<String> = []
        if outcome == "replacement" {
            bridge.show(envelope: message(icon: "", canReply: true))
            try #require(requests.count == 2 && completions.count == 2)
            let current = requests[1].identifier
            #expect(current != old)
            delivered.insert(current)
            completions[1](nil)
            expected.insert(current)
        }
        if outcome == "tombstone" {
            bridge.show(envelope: PlinkEnvelope(id: UUID().uuidString, type: .messageReceived, sentAt: Date(),
                sourceDeviceId: "phone", targetDeviceId: "mac", payload: [
                    "notificationKey": .string("fixture-key"), "removed": .bool(true)]))
        }
        if outcome == "clear" { bridge.clearContexts() }
        if outcome == "shutdown" { bridge.shutdown() }
        if outcome == "dismiss" {
            bridge.handleResponse(id: old, action: UNNotificationDismissActionIdentifier, text: nil)
        }
        if outcome == "reply" {
            bridge.handleResponse(id: old, action: "message.reply", text: "Synthetic reply")
        }
        // Model the OS add landing after retirement, then invoking its held completion.
        delivered.insert(old)
        completions[0](nil)
        #expect(delivered == expected)
        let priorReplies = replies.count
        bridge.handleResponse(id: old, action: "message.reply", text: "Stale synthetic reply")
        #expect(replies.count == priorReplies)
        if let current = expected.first {
            bridge.handleResponse(id: current, action: "message.reply", text: "Current synthetic reply")
            #expect(replies.count == priorReplies + 1)
        }
    }

    @Test(arguments: [false, true], ["reply", "readonly", "unkeyed"])
    func sameIDMessageLateCompletionPreservesCurrent(oldCompletesLast: Bool, kind: String) throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var delivered: Set<String> = []
        var replies: [ReplyContext] = []
        let bridge = NotificationBridge(removeNotifications: { delivered.subtract($0) },
            addNotification: { requests.append($0); completions.append($1) })
        bridge.onTextReply = { context, _ in replies.append(context) }
        let template = message(icon: "", canReply: kind == "reply")
        let original = PlinkEnvelope(id: template.id, type: template.type, sentAt: template.sentAt,
            sourceDeviceId: template.sourceDeviceId, targetDeviceId: template.targetDeviceId,
            payload: template.payload.filter { kind != "unkeyed" || $0.key != "notificationKey" })
        bridge.show(envelope: original)
        let replacement = PlinkEnvelope(id: original.id, type: .messageReceived, sentAt: Date(),
            sourceDeviceId: "phone", targetDeviceId: "mac", payload: original.payload.merging([
                "replyToken": .string("replacement-token")]) { _, new in new })
        bridge.show(envelope: replacement)
        try #require(requests.count == 2 && completions.count == 2)
        let current = requests[1].identifier
        #expect(current == requests[0].identifier)
        delivered.insert(current)
        if oldCompletesLast { completions[1](nil) }
        completions[0](nil)
        #expect(delivered == [current])
        if !oldCompletesLast { completions[1](nil) }
        completions[1](nil) // Duplicate current completion must also preserve ownership.
        #expect(delivered == [current])
        bridge.handleResponse(id: current, action: "message.reply", text: "Synthetic reply")
        #expect(replies.count == (kind == "reply" ? 1 : 0))
        if kind == "reply" { #expect(replies.first?.replyToken == "replacement-token") }
    }

    @Test(arguments: [false, true])
    func equalTextMessagesKeepDistinctKeyOrPeerOwnership(otherPeer: Bool) throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var delivered: Set<String> = []
        let bridge = NotificationBridge(removeNotifications: { delivered.subtract($0) },
            addNotification: { requests.append($0); completions.append($1) })
        let original = message(icon: "")
        bridge.show(envelope: original)
        bridge.show(envelope: PlinkEnvelope(id: UUID().uuidString, type: original.type, sentAt: original.sentAt,
            sourceDeviceId: otherPeer ? "other-phone" : original.sourceDeviceId,
            targetDeviceId: original.targetDeviceId, payload: original.payload.merging([
                "notificationKey": .string(otherPeer ? "fixture-key" : "other-key")]) { _, new in new }))
        try #require(requests.count == 2 && completions.count == 2)
        delivered.formUnion(requests.map(\.identifier))
        completions[0](nil)
        completions[1](nil)
        completions[0](nil)
        completions[1](nil)
        #expect(delivered.count == 2)
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
        let envelope = message(icon: try png().base64EncodedString(), canReply: true)
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
        bridge.show(envelope: message(icon: try png().base64EncodedString(), canReply: true))
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


    @Test func validArtworkRemainsPlainAndPreservesTextAndReply() throws {
        var requests: [UNNotificationRequest] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var replies: [ReplyContext] = []
        let bridge = NotificationBridge(removeNotifications: { _ in },
            addNotification: { requests.append($0); completions.append($1) })
        bridge.onTextReply = { context, _ in replies.append(context) }
        let envelope = message(icon: try png().base64EncodedString(), canReply: true)
        bridge.show(envelope: envelope, pairedPhoneName: "Trusted phone")
        let request = try #require(requests.first)
        #expect(request.identifier == "plink.message-\(envelope.id)")
        #expect(request.content.title == "Sender")
        #expect(request.content.subtitle == "Chat · Trusted phone")
        #expect(request.content.body == "Preview")
        #expect(request.content.categoryIdentifier == "plink.message")
        #expect(request.content.attachments.isEmpty)
        completions[0](nil)
        bridge.handleResponse(id: request.identifier, action: "message.reply", text: "Fixture reply")
        #expect(replies.first?.pairedDeviceId == "phone")
        #expect(replies.first?.packageName == "test.chat")
        #expect(replies.first?.replyToken == "synthetic-token")
    }

    @Test func composedArtworkIsOneBoundedPNGAndRetainsSourceColor() throws {
        let encoded = try png().base64EncodedString()
        let rendered = try #require(NotificationArtwork.renderedPNG(encoded))
        #expect(rendered.count <= 16_384)
        let source = try #require(CGImageSourceCreateWithData(rendered as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 96 && image.height == 96)
        // Sample the decoded production output, not a separate rendering policy.
        let context = try #require(CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8,
            bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let center = (48 * 96 + 48) * 4
        #expect(pixels[center] < 10 && pixels[center + 2] > 240)
        // Circular backing adds light pixels over the otherwise solid blue source.
        let lightPixels = (0..<(96 * 96)).filter { pixels[$0 * 4] > 220 && pixels[$0 * 4 + 1] > 220 && pixels[$0 * 4 + 2] > 220 }.count
        #expect(lightPixels > 100 && lightPixels < 700)
    }

    @Test func malformedAndOversizedArtworkDoesNotAffectPlainDelivery() throws {
        let valid = try png()
        // A syntactically complete APNG control chunk, inserted before image data.
        var animated = valid
        let control: [UInt8] = [0,0,0,8, 97,99,84,76, 0,0,0,2, 0,0,0,0, 243,141,147,112]
        animated.insert(contentsOf: control, at: 33)
        let invalid = ["", "malformed", String(repeating: "A", count: 21_849),
                       Data(repeating: 0, count: 16_385).base64EncodedString(),
                       Data("not PNG".utf8).base64EncodedString(),
                       try png(width: 97).base64EncodedString(), animated.base64EncodedString(),
                       Data(valid.prefix(valid.count / 2)).base64EncodedString()]
        var requests: [UNNotificationRequest] = []
        let bridge = NotificationBridge(submitNotification: { requests.append($0) },
                                        removeNotifications: { _ in })
        for icon in invalid { bridge.show(envelope: message(icon: icon, canReply: true)) }
        #expect(requests.count == invalid.count)
        #expect(requests.allSatisfy { $0.content.attachments.isEmpty && $0.content.categoryIdentifier == "plink.message" })
        #expect(NotificationArtwork.subtitle(appName: "\n", phoneName: "My\tPhone") == "MyPhone")
        #expect(NotificationArtwork.subtitle(appName: nil, phoneName: nil) == "Phone")
    }

    @Test func startupCleanupOnlyRemovesOwnedOrphansAndCompletionLeavesMovedFileAlone() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent("submission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        let artwork = NotificationArtwork.Staging(directory: root)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        let stageValue = artwork.stage(try png().base64EncodedString())
        let stage = try #require(stageValue)
        let owned = root.appendingPathComponent("submission-\(stage.id.uuidString)").appendingPathComponent("source.png")
        let moved = root.appendingPathComponent("daemon-owned.png")
        try FileManager.default.moveItem(at: owned, to: moved)
        artwork.finish(stage)
        artwork.finish(stage)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(artwork.pendingCount == 0)
    }

    @Test func mirroredCallsNeverGainMessageArtwork() throws {
        var requests: [UNNotificationRequest] = []
        let bridge = NotificationBridge(submitNotification: { requests.append($0) }, removeNotifications: { _ in })
        bridge.show(envelope: PlinkEnvelope(id: UUID().uuidString, type: .callRinging, sentAt: Date(),
            sourceDeviceId: "phone", targetDeviceId: "mac", payload: [
                "notificationKey": .string("call-key"), "sourceAppName": .string("Chat"),
                "sourceAppIconPng": .string(try png().base64EncodedString())]), pairedPhoneName: "Trusted phone")
        #expect(requests.count == 1)
        #expect(requests.first?.content.attachments.isEmpty == true)
        #expect(requests.first?.content.subtitle == "Chat · Trusted phone")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("plink-artwork-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func png(width: Int = 96) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: 96, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.48, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 96))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
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

import Foundation
import PlinkCore
import Testing

@Test
func replyRouterBuildsPairedDeviceReplyEnvelope() throws {
    let context = ReplyContext(
        sourceEnvelopeId: "evt-1",
        pairedDeviceId: "pixel",
        macDeviceId: "mac",
        packageName: "com.example.messages",
        notificationKey: "key",
        conversationId: "thread",
        replyToken: "token"
    )

    let reply = try ReplyRouter.makeReplyEnvelope(
        context: context,
        text: "\t  Plink encrypted roundtrip ✓\nCafe\u{0301} 👩‍💻\n  ",
        sentAt: Date(timeIntervalSince1970: 1),
        id: "reply-1"
    )

    #expect(reply.type == .messageReply)
    #expect(reply.sourceDeviceId == "mac")
    #expect(reply.targetDeviceId == "pixel")
    #expect(reply.payload["sourceEnvelopeId"] == .string("evt-1"))
    let expected = "\t  Plink encrypted roundtrip ✓\nCafe\u{0301} 👩‍💻\n  "
    let actual = try #require(reply.payload["text"]?.stringValue)
    #expect(Array(actual.utf8) == Array(expected.utf8))

    let encoded = try JSONEncoder().encode(reply)
    let decoded = try JSONDecoder().decode(PlinkEnvelope.self, from: encoded)
    let decodedText = try #require(decoded.payload["text"]?.stringValue)
    #expect(Array(decodedText.utf8) == Array(expected.utf8))
}

@Test
func replyRouterRejectsBlankReplies() throws {
    let context = ReplyContext(
        sourceEnvelopeId: "evt-1",
        pairedDeviceId: "pixel",
        macDeviceId: "mac",
        packageName: "pkg",
        notificationKey: "key",
        conversationId: nil,
        replyToken: "token"
    )

    #expect(throws: ReplyRouterError.self) {
        _ = try ReplyRouter.makeReplyEnvelope(context: context, text: "\t\r\n ")
    }
}

@Test(arguments: [
    "  reply  ",
    "\tfirst\r\nsecond\n ",
    "e\u{0301}|é|👩🏽‍💻|🇺🇳|終\n",
    "\n\t x \t\n"
])
func replyRouterPreservesExactUTF8Bytes(_ text: String) throws {
    let context = ReplyContext(
        sourceEnvelopeId: "evt-1",
        pairedDeviceId: "pixel",
        macDeviceId: "mac",
        packageName: "pkg",
        notificationKey: "key",
        conversationId: nil,
        replyToken: "token"
    )

    let reply = try ReplyRouter.makeReplyEnvelope(context: context, text: text)
    let actual = try #require(reply.payload["text"]?.stringValue)

    #expect(Array(actual.utf8) == Array(text.utf8))
}

@Test
func replyRouterRejectsTextAboveExistingLimit() {
    #expect(throws: ReplyRouterError.replyTooLong) {
        try ReplyRouter.validateReplyText(String(repeating: "x", count: 4_001))
    }
}

@Test(arguments: ["😀", "e\u{0301}"])
func replyLengthMatchesAndroidUTF16Units(_ unit: String) throws {
    let context = ReplyContext(
        sourceEnvelopeId: "evt-1", pairedDeviceId: "pixel", macDeviceId: "mac",
        packageName: "pkg", notificationKey: "key", conversationId: nil, replyToken: "token"
    )
    let boundary = String(repeating: unit, count: 2_000)
    #expect(boundary.utf16.count == 4_000)
    var envelope = try ReplyRouter.makeReplyEnvelope(context: context, text: boundary)
    try PayloadPolicy.validate(envelope)
    #expect(Array(envelope.payload["text"]!.stringValue!.utf8) == Array(boundary.utf8))

    let tooLong = boundary + unit
    #expect(throws: ReplyRouterError.replyTooLong) {
        try ReplyRouter.validateReplyText(tooLong)
    }
    envelope.payload["text"] = .string(tooLong)
    #expect(throws: PayloadPolicyError.envelopeTooLarge) {
        try PayloadPolicy.validate(envelope)
    }
    var bookkeeping = MacNotificationBookkeeping()
    bookkeeping.store(notificationID: "message", peerID: "pixel", notificationKey: "key", context: context)
    // Match the notification handler: validate before taking its one-use capability.
    do {
        try ReplyRouter.validateReplyText(tooLong)
        _ = bookkeeping.takeReply(notificationID: "message")
        Issue.record("Oversized Unicode reply reached capability consumption")
    } catch ReplyRouterError.replyTooLong {}
    #expect(bookkeeping.takeReply(notificationID: "message") == context)
}

@Test
func replyContextDerivesFromMessageEnvelope() throws {
    let envelope = PlinkEnvelope(
        id: "evt-1",
        type: .messageReceived,
        sentAt: .now,
        sourceDeviceId: "pixel",
        targetDeviceId: "mac",
        payload: [
            "canReply": .bool(true),
            "packageName": .string("com.example.messages"),
            "notificationKey": .string("key"),
            "conversationId": .string("thread"),
            "replyToken": .string("token")
        ]
    )

    let context = try #require(ReplyRouter.context(from: envelope))

    #expect(context.pairedDeviceId == "pixel")
    #expect(context.macDeviceId == "mac")
    #expect(context.notificationKey == "key")
}

@Test
func replyContextRequiresReplyCapabilityAndRouteFields() throws {
    let nonReplyable = PlinkEnvelope(
        id: "evt-1",
        type: .messageReceived,
        sentAt: .now,
        sourceDeviceId: "pixel",
        targetDeviceId: "mac",
        payload: [
            "canReply": .bool(false),
            "packageName": .string("pkg"),
            "notificationKey": .string("key"),
            "replyToken": .string("token")
        ]
    )

    #expect(ReplyRouter.context(from: nonReplyable) == nil)

    let missingRoute = PlinkEnvelope(
        id: "evt-2",
        type: .messageReceived,
        sentAt: .now,
        sourceDeviceId: "pixel",
        targetDeviceId: "mac",
        payload: ["canReply": .bool(true)]
    )

    #expect(ReplyRouter.context(from: missingRoute) == nil)
}

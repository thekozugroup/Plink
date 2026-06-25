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
        text: " On it ",
        sentAt: Date(timeIntervalSince1970: 1),
        id: "reply-1"
    )

    #expect(reply.type == .messageReply)
    #expect(reply.sourceDeviceId == "mac")
    #expect(reply.targetDeviceId == "pixel")
    #expect(reply.payload["sourceEnvelopeId"] == .string("evt-1"))
    #expect(reply.payload["text"] == .string("On it"))
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
        _ = try ReplyRouter.makeReplyEnvelope(context: context, text: " ")
    }
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

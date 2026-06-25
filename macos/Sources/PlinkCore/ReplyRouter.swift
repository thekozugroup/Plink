import Foundation

public struct ReplyContext: Equatable, Sendable {
    public var sourceEnvelopeId: String
    public var pairedDeviceId: String
    public var macDeviceId: String
    public var packageName: String
    public var notificationKey: String
    public var conversationId: String?
    public var replyToken: String

    public init(
        sourceEnvelopeId: String,
        pairedDeviceId: String,
        macDeviceId: String,
        packageName: String,
        notificationKey: String,
        conversationId: String?,
        replyToken: String
    ) {
        self.sourceEnvelopeId = sourceEnvelopeId
        self.pairedDeviceId = pairedDeviceId
        self.macDeviceId = macDeviceId
        self.packageName = packageName
        self.notificationKey = notificationKey
        self.conversationId = conversationId
        self.replyToken = replyToken
    }
}

public enum ReplyRouterError: Error, Equatable {
    case emptyReply
    case missingRoute
}

public enum ReplyRouter {
    public static func makeReplyEnvelope(
        context: ReplyContext,
        text: String,
        sentAt: Date = .now,
        id: String = "reply_\(UUID().uuidString)"
    ) throws -> PlinkEnvelope {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReplyRouterError.emptyReply }
        guard !context.pairedDeviceId.isEmpty, !context.macDeviceId.isEmpty, !context.sourceEnvelopeId.isEmpty else {
            throw ReplyRouterError.missingRoute
        }

        var payload: [String: PayloadValue] = [
            "sourceEnvelopeId": .string(context.sourceEnvelopeId),
            "packageName": .string(context.packageName),
            "notificationKey": .string(context.notificationKey),
            "replyToken": .string(context.replyToken),
            "text": .string(trimmed)
        ]
        if let conversationId = context.conversationId {
            payload["conversationId"] = .string(conversationId)
        }

        return PlinkEnvelope(
            id: id,
            type: .messageReply,
            sentAt: sentAt,
            sourceDeviceId: context.macDeviceId,
            targetDeviceId: context.pairedDeviceId,
            requiresAck: true,
            payload: payload
        )
    }

    public static func context(from envelope: PlinkEnvelope) -> ReplyContext? {
        guard envelope.type == .messageReceived else { return nil }
        return ReplyContext(
            sourceEnvelopeId: envelope.id,
            pairedDeviceId: envelope.sourceDeviceId,
            macDeviceId: envelope.targetDeviceId,
            packageName: envelope.payload["packageName"]?.stringValue ?? "unknown",
            notificationKey: envelope.payload["notificationKey"]?.stringValue ?? envelope.id,
            conversationId: envelope.payload["conversationId"]?.stringValue,
            replyToken: envelope.payload["replyToken"]?.stringValue ?? envelope.id
        )
    }
}

import Foundation

public struct ReplyContext: Codable, Equatable, Sendable {
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

public protocol ReplyContextStoring: Sendable {
    func save(_ context: ReplyContext, notificationId: String) throws
    func take(notificationId: String) throws -> ReplyContext?
}

public final class InMemoryReplyContextStore: ReplyContextStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [String: ReplyContext] = [:]

    public init() {}

    public func save(_ context: ReplyContext, notificationId: String) {
        lock.withLock { contexts[notificationId] = context }
    }

    public func take(notificationId: String) -> ReplyContext? {
        lock.withLock { contexts.removeValue(forKey: notificationId) }
    }
}

public final class UserDefaultsReplyContextStore: ReplyContextStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "app.plink.replyContexts") {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ context: ReplyContext, notificationId: String) throws {
        try lock.withLock {
            var contexts = try loadAll()
            contexts[notificationId] = context
            try persist(contexts)
        }
    }

    public func take(notificationId: String) throws -> ReplyContext? {
        try lock.withLock {
            var contexts = try loadAll()
            let context = contexts.removeValue(forKey: notificationId)
            try persist(contexts)
            return context
        }
    }

    private func loadAll() throws -> [String: ReplyContext] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return try JSONDecoder().decode([String: ReplyContext].self, from: data)
    }

    private func persist(_ contexts: [String: ReplyContext]) throws {
        defaults.set(try JSONEncoder().encode(contexts), forKey: key)
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
        guard envelope.payload["canReply"]?.boolValue == true else { return nil }
        guard
            let packageName = envelope.payload["packageName"]?.stringValue,
            let notificationKey = envelope.payload["notificationKey"]?.stringValue,
            let replyToken = envelope.payload["replyToken"]?.stringValue,
            !packageName.isEmpty,
            !notificationKey.isEmpty,
            !replyToken.isEmpty
        else {
            return nil
        }
        return ReplyContext(
            sourceEnvelopeId: envelope.id,
            pairedDeviceId: envelope.sourceDeviceId,
            macDeviceId: envelope.targetDeviceId,
            packageName: packageName,
            notificationKey: notificationKey,
            conversationId: envelope.payload["conversationId"]?.stringValue,
            replyToken: replyToken
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

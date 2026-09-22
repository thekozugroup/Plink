import Foundation

public struct NotificationActionSlot: Equatable, Sendable {
    public enum Kind: String, Sendable { case invoke, text, phone }
    public let label: String
    public let kind: Kind
    public let authenticationRequired: Bool
    public let token: String?
    public let inputLabel: String?
    public let destructive: Bool
    public let reason: String?
}

public struct NotificationActionOffer: Equatable, Sendable {
    public let source: PlinkEnvelope
    public let session: String
    public let epoch: Int
    public let revision: Int
    public let expires: Date
    public let packageName: String
    public let notificationKey: String
    public let slots: [NotificationActionSlot]
    public let overflow: Int
    public var removed: Bool { source.payload["removed"]?.boolValue == true }

    public init?(_ envelope: PlinkEnvelope) {
        let p = envelope.payload
        guard envelope.type == .messageReceived, p["actionsVersion"] == .int(1),
              let session = p["actionsSession"]?.stringValue, NotificationActionPolicy.uuid(session),
              let epoch = NotificationActionPolicy.counter(p["actionsEpoch"]), epoch > 0,
              let revision = NotificationActionPolicy.counter(p["actionsRevision"]), revision > 0,
              let expiry = NotificationActionPolicy.counter(p["actionsExpiresAtMs"]),
              Double(expiry) <= envelope.sentAt.timeIntervalSince1970 * 1000 + 600_000,
              let count = NotificationActionPolicy.counter(p["actionsCount"]), count <= 10,
              let overflow = NotificationActionPolicy.counter(p["actionsOverflowCount"]),
              let package = p["packageName"]?.stringValue, NotificationActionPolicy.string(package, limit: 300),
              let key = p["notificationKey"]?.stringValue, NotificationActionPolicy.string(key, limit: 500),
              NotificationActionPolicy.string(envelope.id, limit: 200),
              p["removed"]?.boolValue != true || count == 0 else { return nil }
        var expected: Set<String> = ["actionsVersion", "actionsSession", "actionsEpoch", "actionsRevision",
            "actionsExpiresAtMs", "actionsCount", "actionsOverflowCount"]
        var slots: [NotificationActionSlot] = []
        for index in 0..<count {
            let prefix = "action\(index)"
            guard let label = p[prefix + "Label"]?.stringValue, NotificationActionPolicy.label(label),
                  let rawKind = p[prefix + "Kind"]?.stringValue, let kind = NotificationActionSlot.Kind(rawValue: rawKind),
                  let auth = p[prefix + "AuthenticationRequired"]?.boolValue else { return nil }
            expected.formUnion([prefix + "Label", prefix + "Kind", prefix + "AuthenticationRequired"])
            var destructive = false
            if let value = p[prefix + "Destructive"] {
                guard let flag = value.boolValue else { return nil }
                destructive = flag; expected.insert(prefix + "Destructive")
            }
            var token: String?, inputLabel: String?, reason: String?
            if kind == .phone {
                guard let value = p[prefix + "Reason"]?.stringValue,
                      NotificationActionPolicy.phoneReasons.contains(value) else { return nil }
                reason = value; expected.insert(prefix + "Reason")
            } else {
                guard let value = p[prefix + "Token"]?.stringValue, NotificationActionPolicy.uuid(value) else { return nil }
                token = value; expected.insert(prefix + "Token")
                if kind == .text, let value = p[prefix + "InputLabel"] {
                    guard let text = value.stringValue, NotificationActionPolicy.label(text) else { return nil }
                    inputLabel = text; expected.insert(prefix + "InputLabel")
                }
            }
            slots.append(NotificationActionSlot(label: label, kind: kind, authenticationRequired: auth,
                token: token, inputLabel: inputLabel, destructive: destructive, reason: reason))
        }
        guard Set(p.keys.filter(NotificationActionPolicy.isReserved)) == expected else { return nil }
        source = envelope; self.session = session; self.epoch = epoch; self.revision = revision
        expires = Date(timeIntervalSince1970: Double(expiry) / 1000)
        packageName = package; notificationKey = key; self.slots = slots; self.overflow = overflow
    }

    public func invocation(index: Int, text: String?, now: Date = .now) throws -> PlinkEnvelope {
        guard slots.indices.contains(index), expires > now, !removed,
              let token = slots[index].token else { throw NotificationActionPolicy.Invalid.payload }
        let slot = slots[index]
        var payload: [String: PayloadValue] = ["actionsVersion": .int(1), "actionsSession": .string(session),
            "actionsEpoch": .int(epoch), "sourceEnvelopeId": .string(source.id),
            "packageName": .string(packageName), "notificationKey": .string(notificationKey),
            "actionIndex": .int(index), "actionToken": .string(token)]
        if slot.kind == .text {
            guard let text else { throw NotificationActionPolicy.Invalid.payload }
            try ReplyRouter.validateReplyText(text)
            payload["text"] = .string(text)
        } else if text != nil { throw NotificationActionPolicy.Invalid.payload }
        return PlinkEnvelope(id: UUID().uuidString.lowercased(), type: .notificationAction, sentAt: now,
            sourceDeviceId: source.targetDeviceId, targetDeviceId: source.sourceDeviceId, requiresAck: true, payload: payload)
    }
}

public enum NotificationActionPolicy {
    public enum Invalid: Error { case payload }
    static let phoneReasons: Set<String> = ["missing_intent", "data_input", "choice_input", "multiple_inputs",
        "invalid_label", "unsupported_input", "immutable_input"]
    public static let errorCodes: Set<String> = ["phone_locked", "stale_action", "action_expired", "actions_disabled",
        "action_not_enabled", "unsupported_input", "action_canceled", "invalid_action"]
    private static let integerKeys: Set<String> = ["actionsVersion", "actionsEpoch", "actionsRevision", "actionsExpiresAtMs",
        "actionsCount", "actionsOverflowCount", "actionIndex"]
    public static func isReserved(_ key: String) -> Bool {
        key.hasPrefix("actions") || key.range(of: #"^action[0-9]+"#, options: .regularExpression) != nil
    }
    public static func hasExtension(_ payload: [String: PayloadValue]) -> Bool { payload.keys.contains(where: isReserved) }
    static func counter(_ value: PayloadValue?) -> Int? {
        guard case .int(let number) = value, number >= 0, number <= 9_007_199_254_740_991 else { return nil }
        return number
    }
    static func uuid(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }
    static func string(_ value: String, limit: Int) -> Bool { !value.isEmpty && value.unicodeScalars.count <= limit }
    static func label(_ value: String) -> Bool {
        string(value, limit: 128) && value.utf8.count <= 512 && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public static func isControl(_ envelope: PlinkEnvelope) -> Bool {
        [.notificationActionsEnable, .notificationActionsState, .notificationAction].contains(envelope.type) ||
            ((envelope.type == .ack || envelope.type == .error) && hasExtension(envelope.payload))
    }

    /// The existing lexical reader preserves numeric spelling. Invalid optional offers lose
    /// only capability fields; their text still passes through the ordinary scalar decoder.
    static func prepareForDecoding(_ data: Data) throws -> Data {
        guard data.count <= PayloadPolicy.maxEnvelopeBytes else { throw PayloadPolicyError.envelopeTooLarge }
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var payload = root["payload"] as? [String: Any], let type = root["type"] as? String else { return data }
        let offer = type == "message.received" && payload.keys.contains(where: isReserved)
        let control = ["notification.actions.enable", "notification.actions.state", "notification.action"].contains(type) ||
            (["ack", "error"].contains(type) && payload.keys.contains(where: isReserved))
        guard offer || control else { return data }
        do {
            var parser = StrictJSONParser(String(decoding: data, as: UTF8.self))
            let object = try parser.parse().objectValue()
            guard let rawPayload = object["payload"] else { throw Invalid.payload }
            let members = try rawPayload.objectValue()
            for key in integerKeys where members[key] != nil {
                let token = try members[key]!.numberValue()
                guard token.range(of: #"^(-?0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
                      let value = Int(token), value <= 9_007_199_254_740_991 else { throw Invalid.payload }
            }
            // Nested optional metadata cannot prevent delivery of otherwise valid ordinary text.
            for (key, value) in members where isReserved(key) {
                switch value { case .object, .array, .null: throw Invalid.payload; default: break }
            }
        } catch {
            guard offer else { throw Invalid.payload }
            for key in Array(payload.keys) where isReserved(key) { payload.removeValue(forKey: key) }
            payload["actionsVersion"] = -1 // Explicitly unusable extension; never re-enable legacy Reply.
            root["payload"] = payload
            return try JSONSerialization.data(withJSONObject: root)
        }
        return data
    }

    public static func validate(_ envelope: PlinkEnvelope) throws {
        guard isControl(envelope) else { return }
        let p = envelope.payload
        guard p["actionsVersion"] == .int(1), let session = p["actionsSession"]?.stringValue, uuid(session) else { throw Invalid.payload }
        var expected: Set<String> = ["actionsVersion", "actionsSession"]
        switch envelope.type {
        case .notificationActionsEnable:
            guard envelope.requiresAck else { throw Invalid.payload }
        case .notificationActionsState:
            expected.formUnion(["actionsEpoch", "state"])
            guard let epoch = counter(p["actionsEpoch"]), epoch > 0,
                  ["enabled", "disabled"].contains(p["state"]?.stringValue ?? ""), !envelope.requiresAck else { throw Invalid.payload }
        case .notificationAction:
            expected.formUnion(["actionsEpoch", "sourceEnvelopeId", "packageName", "notificationKey", "actionIndex", "actionToken"])
            guard envelope.requiresAck, let epoch = counter(p["actionsEpoch"]), epoch > 0,
                  let index = counter(p["actionIndex"]), index < 10,
                  let token = p["actionToken"]?.stringValue, uuid(token) else { throw Invalid.payload }
            for (key, bound) in [("sourceEnvelopeId", 200), ("packageName", 300), ("notificationKey", 500)] {
                guard let value = p[key]?.stringValue, string(value, limit: bound) else { throw Invalid.payload }
            }
            if let value = p["text"] {
                guard let text = value.stringValue else { throw Invalid.payload }
                try ReplyRouter.validateReplyText(text); expected.insert("text")
            }
        case .ack, .error:
            expected.formUnion(["eventId", "action"])
            guard let eventID = p["eventId"]?.stringValue, string(eventID, limit: 200),
                  let action = p["action"]?.stringValue,
                  [EventType.notificationActionsEnable.rawValue, EventType.notificationAction.rawValue].contains(action) else { throw Invalid.payload }
            if envelope.type == .ack {
                expected.insert("status")
                if action == EventType.notificationActionsEnable.rawValue {
                    expected.insert("actionsEpoch")
                    guard p["status"] == .string("enabled"), let epoch = counter(p["actionsEpoch"]), epoch > 0 else { throw Invalid.payload }
                } else if p["status"] != .string("dispatched") { throw Invalid.payload }
            } else {
                expected.insert("code")
                guard let code = p["code"]?.stringValue, errorCodes.contains(code) else { throw Invalid.payload }
                if p["message"] != nil {
                    guard let message = p["message"]?.stringValue, message.utf8.count <= 1024 else { throw Invalid.payload }
                    expected.insert("message")
                }
            }
        default: throw Invalid.payload
        }
        guard Set(p.keys) == expected else { throw Invalid.payload }
    }

    public static func failureMessage(_ code: String) -> String {
        switch code {
        case "phone_locked": return "Unlock your phone."
        case "action_expired", "stale_action": return "That action expired. Use the latest notification."
        case "actions_disabled", "action_not_enabled": return "Notification actions are unavailable. Check your phone."
        case "unsupported_input": return "Complete this action on your phone."
        case "action_canceled": return "This action is no longer available on your phone."
        default: return "The phone could not perform this action."
        }
    }
}

import Foundation

public struct PlinkEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var type: EventType
    public var sentAt: Date
    public var sourceDeviceId: String
    public var targetDeviceId: String
    public var requiresAck: Bool
    public var payload: [String: PayloadValue]

    public init(
        version: Int = 1,
        id: String,
        type: EventType,
        sentAt: Date,
        sourceDeviceId: String,
        targetDeviceId: String,
        requiresAck: Bool = false,
        payload: [String: PayloadValue]
    ) {
        self.version = version
        self.id = id
        self.type = type
        self.sentAt = sentAt
        self.sourceDeviceId = sourceDeviceId
        self.targetDeviceId = targetDeviceId
        self.requiresAck = requiresAck
        self.payload = payload
    }
}

public enum PayloadValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

public enum EventType: String, Codable, Sendable {
    case pairingOffer = "pairing.offer"
    case pairingConfirm = "pairing.confirm"
    case deviceStatus = "device.status"
    case callRinging = "call.ringing"
    case callEnded = "call.ended"
    case messageReceived = "message.received"
    case messageReply = "message.reply"
    case clipboardUpdated = "clipboard.updated"
    case fileOffer = "file.offer"
    case webOpen = "web.open"
    case mediaState = "media.state"
    case mediaCommand = "media.command"
    case permissionState = "permission.state"
    case ack
    case error
}

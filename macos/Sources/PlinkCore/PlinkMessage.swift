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

    /// Use for wire input so event-specific raw JSON policies run alongside typed decoding.
    public static func decode(
        _ data: Data,
        reconnectValidation: ReconnectValidationPolicy = .production
    ) throws -> PlinkEnvelope {
        let envelope = try PlinkJSON.decoder().decode(PlinkEnvelope.self, from: data)
        if ReconnectPayloadPolicy.eventTypes.contains(envelope.type) {
            try ReconnectPayloadPolicy.validateRawJSON(data, validation: reconnectValidation)
        }
        try FileTransferPayloadPolicy.validateRawJSON(data)
        try ScreenPreviewPayloadPolicy.validateRawJSON(data)
        try ReconnectPayloadPolicy.validate(envelope, validation: reconnectValidation, plaintextBytes: data.count)
        return envelope
    }

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

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}

public enum EventType: String, Codable, Hashable, Sendable {
    case pairingOffer = "pairing.offer"
    case pairingConfirm = "pairing.confirm"
    case deviceStatus = "device.status"
    case callRinging = "call.ringing"
    case callEnded = "call.ended"
    case messageReceived = "message.received"
    case messageReply = "message.reply"
    case clipboardUpdated = "clipboard.updated"
    case fileOffer = "file.offer"
    case fileAccept = "file.accept"
    case fileChunk = "file.chunk"
    case fileProgress = "file.progress"
    case fileComplete = "file.complete"
    case fileResult = "file.result"
    case fileCancel = "file.cancel"
    case screenRequest = "screen.request"
    case screenState = "screen.state"
    case screenPull = "screen.pull"
    case screenFrame = "screen.frame"
    case screenIdle = "screen.idle"
    case screenStop = "screen.stop"
    case webOpen = "web.open"
    case mediaState = "media.state"
    case mediaCommand = "media.command"
    case permissionState = "permission.state"
    case reconnectHello = "reconnect.hello"
    case reconnectChallenge = "reconnect.challenge"
    case reconnectProof = "reconnect.proof"
    case reconnectReverse = "reconnect.reverse"
    case reconnectReverseProof = "reconnect.reverse_proof"
    case reconnectReady = "reconnect.ready"
    case reconnectCommit = "reconnect.commit"
    case reconnectDone = "reconnect.done"
    case ack
    case error
}

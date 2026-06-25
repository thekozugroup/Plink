import Foundation

public struct PlinkEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var type: EventType
    public var sentAt: Date
    public var sourceDeviceId: String
    public var targetDeviceId: String
    public var requiresAck: Bool
    public var payload: [String: String]

    public init(
        version: Int = 1,
        id: String,
        type: EventType,
        sentAt: Date,
        sourceDeviceId: String,
        targetDeviceId: String,
        requiresAck: Bool = false,
        payload: [String: String]
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

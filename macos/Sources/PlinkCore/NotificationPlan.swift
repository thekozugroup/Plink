import Foundation

public struct NativeNotificationPlan: Equatable, Sendable {
    public var categoryIdentifier: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var allowsTextReply: Bool
    public var continuityResponseType: EventType?

    public init(
        categoryIdentifier: String,
        title: String,
        subtitle: String = "",
        body: String,
        allowsTextReply: Bool = false,
        continuityResponseType: EventType? = nil
    ) {
        self.categoryIdentifier = categoryIdentifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.allowsTextReply = allowsTextReply
        self.continuityResponseType = continuityResponseType
    }
}

public enum NotificationPlanner {
    public static func plan(for envelope: PlinkEnvelope) -> NativeNotificationPlan? {
        switch envelope.type {
        case .callRinging:
            return NativeNotificationPlan(
                categoryIdentifier: "plink.call",
                title: "Incoming call",
                subtitle: envelope.payload["callerName"]?.stringValue ?? "Pixel",
                body: envelope.payload["callerHandle"]?.stringValue ?? "Unknown caller"
            )
        case .messageReceived:
            return NativeNotificationPlan(
                categoryIdentifier: "plink.message",
                title: envelope.payload["sender"]?.stringValue ?? "Message",
                body: envelope.payload["preview"]?.stringValue ?? "",
                allowsTextReply: envelope.payload["canReply"]?.boolValue ?? false,
                continuityResponseType: .messageReply
            )
        case .clipboardUpdated:
            return NativeNotificationPlan(
                categoryIdentifier: "plink.info",
                title: "Clipboard from Pixel",
                body: envelope.payload["text"]?.stringValue ?? "New clipboard item"
            )
        default:
            return nil
        }
    }
}

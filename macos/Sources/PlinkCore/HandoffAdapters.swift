import Foundation

public protocol ClipboardWriting {
    func writeText(_ text: String)
}

public protocol URLOpening {
    func open(_ url: URL)
}

public struct HandoffAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case clipboard(String)
        case openURL(URL)
        case fileOffer(String)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

public enum HandoffPlanner {
    public static func action(for envelope: PlinkEnvelope) -> HandoffAction? {
        switch envelope.type {
        case .clipboardUpdated:
            guard let text = envelope.payload["text"]?.stringValue else { return nil }
            return HandoffAction(kind: .clipboard(text))
        case .webOpen:
            guard
                let raw = envelope.payload["url"]?.stringValue,
                PayloadPolicy.isAllowedURL(raw),
                let url = URL(string: raw)
            else { return nil }
            return HandoffAction(kind: .openURL(url))
        case .fileOffer:
            return HandoffAction(kind: .fileOffer(envelope.payload["name"]?.stringValue ?? "Incoming file"))
        default:
            return nil
        }
    }
}

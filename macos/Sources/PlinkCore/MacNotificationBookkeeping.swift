import Foundation

/// Bounded state for message notifications. Call notifications are tracked separately by the app.
public struct MacNotificationBookkeeping: Sendable {
    private struct MessageKey: Hashable, Sendable {
        let peerID: String
        let notificationKey: String
    }

    private struct Entry: Sendable {
        let key: MessageKey
        let context: ReplyContext?
        let expiresAt: Date
        let sequence: UInt64
    }

    public static let capacity = 128
    public static let replyLifetime: TimeInterval = 600

    private var entries: [String: Entry] = [:]
    private var notificationIDsByKey: [MessageKey: String] = [:]
    private var nextSequence: UInt64 = 0

    public init() {}

    public var count: Int { entries.count }

    @discardableResult
    public mutating func store(
        notificationID: String,
        peerID: String,
        notificationKey: String,
        context: ReplyContext?,
        now: Date = .now
    ) -> [String] {
        var obsolete = expire(now: now)
        let key = MessageKey(peerID: peerID, notificationKey: notificationKey)

        if entries[notificationID] != nil {
            removeEntry(notificationID)
            obsolete.append(notificationID)
        }
        if let replaced = notificationIDsByKey[key], replaced != notificationID {
            removeEntry(replaced)
            obsolete.append(replaced)
        }
        while entries.count >= Self.capacity, let oldest = oldestNotificationID() {
            removeEntry(oldest)
            obsolete.append(oldest)
        }

        nextSequence &+= 1
        entries[notificationID] = Entry(
            key: key,
            context: context,
            expiresAt: now.addingTimeInterval(Self.replyLifetime),
            sequence: nextSequence
        )
        notificationIDsByKey[key] = notificationID
        return unique(obsolete)
    }

    public mutating func takeReply(notificationID: String, now: Date = .now) -> ReplyContext? {
        guard let entry = entries[notificationID] else { return nil }
        removeEntry(notificationID)
        guard entry.expiresAt > now else { return nil }
        return entry.context
    }

    @discardableResult
    public mutating func remove(notificationID: String) -> Bool {
        guard entries[notificationID] != nil else { return false }
        removeEntry(notificationID)
        return true
    }

    public mutating func remove(notificationKey: String, peerID: String) -> [String] {
        let key = MessageKey(peerID: peerID, notificationKey: notificationKey)
        guard let notificationID = notificationIDsByKey[key] else { return [] }
        removeEntry(notificationID)
        return [notificationID]
    }

    public mutating func expire(now: Date = .now) -> [String] {
        let expired = entries
            .filter { $0.value.expiresAt <= now }
            .sorted { $0.value.sequence < $1.value.sequence }
            .map(\.key)
        for notificationID in expired { removeEntry(notificationID) }
        return expired
    }

    public mutating func removeAll() -> [String] {
        let notificationIDs = entries
            .sorted { $0.value.sequence < $1.value.sequence }
            .map(\.key)
        entries.removeAll()
        notificationIDsByKey.removeAll()
        return notificationIDs
    }

    private mutating func removeEntry(_ notificationID: String) {
        guard let entry = entries.removeValue(forKey: notificationID) else { return }
        if notificationIDsByKey[entry.key] == notificationID {
            notificationIDsByKey.removeValue(forKey: entry.key)
        }
    }

    private func oldestNotificationID() -> String? {
        entries.min { $0.value.sequence < $1.value.sequence }?.key
    }

    private func unique(_ notificationIDs: [String]) -> [String] {
        var seen = Set<String>()
        return notificationIDs.filter { seen.insert($0).inserted }
    }
}

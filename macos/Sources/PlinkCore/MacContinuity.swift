import Foundation

/// A timed-out foreign-framework call cannot be cancelled by a Swift Task.
/// Quarantine the worker instead of spawning replacement threads.
public struct MacBluetoothOperationGate: Sendable {
    public private(set) var current: UUID?
    public private(set) var blocked = false
    public init() {}
    public mutating func begin() -> UUID? {
        guard current == nil, !blocked else { return nil }
        let id = UUID(); current = id; return id
    }
    public mutating func complete(_ id: UUID) -> Bool {
        guard !blocked, current == id else { return false }
        current = nil; return true
    }
    public mutating func timeout(_ id: UUID) -> Bool {
        guard !blocked, current == id else { return false }
        blocked = true; return true
    }
}

public enum MacCallAction: String, Sendable { case answer, decline, hangUp, computerAudio, phoneAudio, toggleMute }

extension MacCallAction {
    public func completesOnSCO(connected: Bool) -> Bool {
        self == .computerAudio || (self == .phoneAudio && !connected)
    }
}

public struct MacCallContext: Equatable, Sendable {
    public let phoneID: String
    public let callID: UUID
}

/// HFP observations, not successful method invocation, determine call state.
public struct MacCallSession: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, ringing, answering, active, ending }
    public enum Audio: String, Sendable { case unavailable, requestedComputer, scoConnectedUnverified, phone }
    public private(set) var phoneID: String?
    public private(set) var context: MacCallContext?
    public private(set) var phase: Phase = .idle
    public private(set) var audio: Audio = .unavailable
    public private(set) var number: String?
    public private(set) var muted = false
    public private(set) var hasWaitingCall = false
    private var active = false
    private var observedCallIndex: Int?

    public init() {}
    public mutating func connected(phoneID: String) { self = Self(); self.phoneID = phoneID }
    public mutating func disconnected() { self = Self() }
    public mutating func ringing(number: String?) {
        guard let phoneID else { return }
        if active { hasWaitingCall = true; return }
        if context == nil { context = MacCallContext(phoneID: phoneID, callID: UUID()) }
        if phase != .answering && phase != .ending { phase = .ringing }
        if let number, !number.isEmpty { self.number = String(number.prefix(128)) }
    }
    public mutating func setupEnded() {
        // Setup ending does not prove that a held/waiting call ended.
        if !active && !hasWaitingCall { clearCall() }
    }
    public mutating func observeCall(index: Int?, status: Int) {
        if let index {
            if let previous = observedCallIndex, previous != index { hasWaitingCall = true }
            observedCallIndex = index
        } else { hasWaitingCall = true }
        if status == 1 || status == 5 { hasWaitingCall = true }
        if status == 0 { setActive(true) }
        if status == 4 || status == 5 { ringing(number: nil) }
    }
    public mutating func setActive(_ value: Bool) {
        active = value
        if value, let phoneID {
            if context == nil { context = MacCallContext(phoneID: phoneID, callID: UUID()) }
            if phase != .ending { phase = .active }
        } else if !value { clearCall() }
    }
    public mutating func setSCO(_ connected: Bool) {
        audio = connected ? .scoConnectedUnverified : (context == nil ? .unavailable : .phone)
    }
    public mutating func setMuted(_ value: Bool) { muted = value }
    public func permits(_ action: MacCallAction, context expected: MacCallContext) -> Bool {
        guard context == expected, phoneID == expected.phoneID, !hasWaitingCall else { return false }
        switch action {
        case .answer, .decline: return phase == .ringing && !hasWaitingCall
        case .hangUp: return phase == .active && !hasWaitingCall
        case .computerAudio, .phoneAudio: return phase == .active
        case .toggleMute: return phase == .active && audio == .scoConnectedUnverified
        }
    }
    public mutating func begin(_ action: MacCallAction, context expected: MacCallContext) -> Bool {
        guard permits(action, context: expected) else { return false }
        switch action {
        case .answer: phase = .answering; audio = .requestedComputer
        case .decline, .hangUp: phase = .ending
        case .computerAudio: audio = .requestedComputer
        case .phoneAudio, .toggleMute: break
        }
        return true
    }
    private mutating func clearCall() {
        context = nil; phase = .idle; audio = .unavailable; number = nil; muted = false; hasWaitingCall = false
        observedCallIndex = nil
    }
}

public struct MacCommandResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case executed, awaitingUser, failed(String), unconfirmed }
    public let eventID: String
    public let action: EventType
    public let status: Status
}

public struct MacCommandTracker: Sendable {
    private struct Pending: Sendable { let envelope: PlinkEnvelope; let expires: Date }
    private var pending: [String: Pending] = [:]
    public init() {}
    public mutating func begin(_ envelope: PlinkEnvelope, now: Date = .now) {
        pending[envelope.id] = Pending(envelope: envelope, expires: now.addingTimeInterval(30))
    }
    public mutating func resolve(_ envelope: PlinkEnvelope) -> MacCommandResult? {
        guard envelope.type == .ack || envelope.type == .error,
              let id = envelope.payload["eventId"]?.stringValue,
              let command = pending[id]?.envelope,
              envelope.sourceDeviceId == command.targetDeviceId,
              envelope.targetDeviceId == command.sourceDeviceId else { return nil }
        let status: MacCommandResult.Status
        if envelope.type == .ack {
            guard envelope.payload["action"]?.stringValue == command.type.rawValue else { return nil }
            switch envelope.payload["status"]?.stringValue {
            case "executed": status = .executed
            case "awaiting_user" where command.type == .clipboardUpdated || command.type == .webOpen:
                pending[id] = Pending(envelope: command, expires: .now.addingTimeInterval(600))
                return MacCommandResult(eventID: id, action: command.type, status: .awaitingUser)
            default: return nil
            }
        } else {
            guard let code = envelope.payload["code"]?.stringValue, !code.isEmpty, code.count <= 128 else { return nil }
            status = .failed(code)
        }
        pending.removeValue(forKey: id)
        return MacCommandResult(eventID: id, action: command.type, status: status)
    }
    public mutating func remove(_ id: String) { pending.removeValue(forKey: id) }
    public mutating func expire(now: Date = .now) -> [MacCommandResult] {
        let expired = pending.filter { $0.value.expires <= now }
        for key in expired.keys { pending.removeValue(forKey: key) }
        return expired.map { MacCommandResult(eventID: $0.key, action: $0.value.envelope.type, status: .unconfirmed) }
    }
    public mutating func removeAll() { pending.removeAll() }
}

public struct MacDeviceStatus: Equatable, Sendable {
    public let batteryLevel: Int
    public let charging: Bool
    public let network: String
    public let receivedAt: Date
    public init?(envelope: PlinkEnvelope, now: Date = .now) {
        guard envelope.type == .deviceStatus,
              case .int(let level) = envelope.payload["batteryLevel"], (0...100).contains(level),
              let charging = envelope.payload["charging"]?.boolValue,
              let network = envelope.payload["network"]?.stringValue,
              ["wifi", "cellular", "offline", "other"].contains(network) else { return nil }
        batteryLevel = level; self.charging = charging; self.network = network; receivedAt = now
    }
}

public struct MacMediaState: Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let artist: String
    public let playing: Bool
    public let receivedAt: Date
    private let actions: Set<String>
    public init?(envelope: PlinkEnvelope, now: Date = .now) {
        guard envelope.type == .mediaState,
              let session = envelope.payload["sessionId"]?.stringValue, session.count <= 512,
              let title = envelope.payload["title"]?.stringValue, title.count <= 4096,
              let artist = envelope.payload["artist"]?.stringValue, artist.count <= 4096,
              let playing = envelope.payload["playing"]?.boolValue else { return nil }
        var actions = Set<String>()
        for (command, field) in [("play", "canPlay"), ("pause", "canPause"), ("next", "canNext"), ("previous", "canPrevious")] {
            guard let enabled = envelope.payload[field]?.boolValue else { return nil }
            if enabled && !session.isEmpty { actions.insert(command) }
        }
        sessionID = session; self.title = title; self.artist = artist; self.playing = playing
        receivedAt = now; self.actions = actions
    }
    public func allows(_ command: String) -> Bool { actions.contains(command) }
}

/// These capabilities cannot survive Android's live PendingIntent or our own process.
public struct MacReplyContexts: Sendable {
    private struct Entry: Sendable { let context: ReplyContext; let expires: Date }
    private var entries: [String: Entry] = [:]
    public init() {}
    @discardableResult
    public mutating func store(_ context: ReplyContext, notificationID: String, now: Date = .now) -> [String] {
        let obsolete = entries.filter {
            $0.value.expires <= now || ($0.value.context.pairedDeviceId == context.pairedDeviceId &&
            $0.value.context.packageName == context.packageName && $0.value.context.notificationKey == context.notificationKey)
        }.map(\.key)
        for key in obsolete { entries.removeValue(forKey: key) }
        entries[notificationID] = Entry(context: context, expires: now.addingTimeInterval(600))
        return obsolete
    }
    public mutating func take(_ id: String, now: Date = .now) -> ReplyContext? {
        guard let entry = entries.removeValue(forKey: id), entry.expires > now else { return nil }
        return entry.context
    }
    public mutating func remove(notificationKey: String, peerID: String) -> [String] {
        let keys = entries.filter { $0.value.context.notificationKey == notificationKey && $0.value.context.pairedDeviceId == peerID }.map(\.key)
        for key in keys { entries.removeValue(forKey: key) }
        return keys
    }
    public mutating func expire(now: Date = .now) -> [String] {
        let keys = entries.filter { $0.value.expires <= now }.map(\.key)
        for key in keys { entries.removeValue(forKey: key) }
        return keys
    }
    public mutating func removeAll() { entries.removeAll() }
}

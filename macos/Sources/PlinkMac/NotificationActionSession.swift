import Foundation
import PlinkCore

/// Volatile authority for one authenticated ordinary connection. No timers or retries.
struct NotificationActionSession {
    struct Admission: Equatable {
        let localID: String
        let peerID: String
        let generation: UUID
    }
    struct Key: Hashable { let package: String; let notification: String }
    struct Observation { let retireAll: Bool; let evicted: Key? }
    struct Pending {
        let envelope: PlinkEnvelope
        let expires: Date
        let presentationID: String?
    }
    let admission: Admission
    private(set) var session: String?
    private(set) var epoch = 0
    private(set) var enabled = false
    private(set) var negotiated = false
    private(set) var pending: [String: Pending] = [:]
    private var enableAttempted = false
    private var revisions: [Key: Int] = [:]
    private var revisionFloor = 0
    var watermarkCount: Int { revisions.count }

    init(admission: Admission) { self.admission = admission }

    func hasObservedKey(of envelope: PlinkEnvelope) -> Bool {
        guard envelope.type == .messageReceived,
              envelope.sourceDeviceId == admission.peerID, envelope.targetDeviceId == admission.localID,
              let package = envelope.payload["packageName"]?.stringValue,
              let key = envelope.payload["notificationKey"]?.stringValue else { return false }
        return revisions[Key(package: package, notification: key)] != nil
    }

    mutating func observe(_ offer: NotificationActionOffer) -> Observation? {
        guard offer.source.sourceDeviceId == admission.peerID, offer.source.targetDeviceId == admission.localID,
              session == nil || session == offer.session, offer.epoch >= epoch else { return nil }
        if session == nil { session = offer.session }
        let changedEpoch = offer.epoch > epoch
        if changedEpoch { epoch = offer.epoch; revisions.removeAll(); revisionFloor = 0; retireInvocations() }
        let key = Key(package: offer.packageName, notification: offer.notificationKey)
        guard offer.revision > (revisions[key] ?? revisionFloor) else { return nil }
        var evicted: Key?
        if revisions[key] == nil, revisions.count >= 128,
           let oldest = revisions.min(by: { $0.value < $1.value }) {
            guard offer.revision > oldest.value else { return nil }
            revisionFloor = max(revisionFloor, oldest.value)
            evicted = oldest.key; revisions.removeValue(forKey: oldest.key)
        }
        revisions[key] = offer.revision
        return Observation(retireAll: changedEpoch, evicted: evicted)
    }

    mutating func enable(now: Date) -> PlinkEnvelope? {
        guard !enableAttempted, let session else { return nil }
        enableAttempted = true
        let envelope = PlinkEnvelope(id: UUID().uuidString.lowercased(), type: .notificationActionsEnable,
            sentAt: now, sourceDeviceId: admission.localID, targetDeviceId: admission.peerID, requiresAck: true,
            payload: ["actionsVersion": .int(1), "actionsSession": .string(session)])
        pending[envelope.id] = Pending(envelope: envelope, expires: now.addingTimeInterval(30), presentationID: nil)
        return envelope
    }

    func permits(_ offer: NotificationActionOffer, now: Date) -> Bool {
        enabled && negotiated && offer.session == session && offer.epoch == epoch && offer.expires > now &&
            revisions[Key(package: offer.packageName, notification: offer.notificationKey)] == offer.revision && !offer.removed
    }

    mutating func track(_ envelope: PlinkEnvelope, presentationID: String, now: Date) -> Bool {
        guard pending.count < 1280 else { return false }
        pending[envelope.id] = Pending(envelope: envelope, expires: now.addingTimeInterval(30), presentationID: presentationID)
        return true
    }

    /// A result is consumed only after exact namespace, peer, session, and deadline checks.
    mutating func outcome(_ envelope: PlinkEnvelope, now: Date) -> Pending? {
        guard envelope.type == .ack || envelope.type == .error,
              (try? NotificationActionPolicy.validate(envelope)) != nil,
              let id = envelope.payload["eventId"]?.stringValue, let command = pending[id], command.expires > now,
              envelope.sourceDeviceId == admission.peerID, envelope.targetDeviceId == admission.localID,
              envelope.payload["actionsSession"] == command.envelope.payload["actionsSession"],
              envelope.payload["action"] == .string(command.envelope.type.rawValue) else { return nil }
        pending.removeValue(forKey: id)
        if command.envelope.type == .notificationActionsEnable, envelope.type == .ack,
           let acknowledgedEpoch = envelope.payload["actionsEpoch"]?.intValue {
            if acknowledgedEpoch > epoch { revisions.removeAll(); revisionFloor = 0 }
            epoch = max(epoch, acknowledgedEpoch); negotiated = true; enabled = true
        }
        return command
    }

    mutating func state(_ envelope: PlinkEnvelope) -> Bool {
        guard envelope.type == .notificationActionsState, negotiated,
              (try? NotificationActionPolicy.validate(envelope)) != nil,
              envelope.sourceDeviceId == admission.peerID, envelope.targetDeviceId == admission.localID,
              envelope.payload["actionsSession"] == .string(session ?? ""),
              let nextEpoch = envelope.payload["actionsEpoch"]?.intValue, nextEpoch >= epoch else { return false }
        let nextEnabled = envelope.payload["state"] == .string("enabled")
        let retire = nextEpoch > epoch || !nextEnabled
        if nextEpoch > epoch { revisions.removeAll(); revisionFloor = 0 }
        epoch = nextEpoch; enabled = nextEnabled
        if retire { retireInvocations() }
        return retire
    }

    // Individual presentation retirement revokes execution in the bridge, not bounded result correlation.
    mutating func failed(_ id: String) -> Pending? { pending.removeValue(forKey: id) }
    mutating func expire(now: Date) -> [Pending] {
        let expired = pending.filter { $0.value.expires <= now }
        for id in expired.keys { pending.removeValue(forKey: id) }
        return Array(expired.values)
    }
    private mutating func retireInvocations() { pending = pending.filter { $0.value.presentationID == nil } }
}

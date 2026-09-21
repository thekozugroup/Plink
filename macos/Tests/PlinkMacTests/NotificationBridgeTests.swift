import Foundation
import PlinkCore
import Testing
import UserNotifications
@testable import PlinkMac

@MainActor
struct NotificationBridgeTests {
    @Test func oldMirroredCallRemovalPreservesReplacementUntilItsOwnRemoval() {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        bridge.show(envelope: call(.callRinging, key: "A", caller: "Caller A"))
        bridge.show(envelope: call(.callRinging, key: "B", caller: "Caller B"))
        #expect(notifications.delivered["plink.call.mirrored"]?.body == "Caller B")

        bridge.show(envelope: call(.callEnded, key: "A"))
        #expect(notifications.delivered["plink.call.mirrored"]?.body == "Caller B")
        #expect(notifications.pending["plink.call.mirrored"]?.body == "Caller B")
        #expect(notifications.removals.isEmpty)

        bridge.show(envelope: call(.callEnded, key: "B"))
        #expect(notifications.delivered.isEmpty)
        #expect(notifications.pending.isEmpty)
        #expect(notifications.removals == [["plink.call.mirrored"]])
    }

    @Test func mirroredRemovalRequiresTheSamePeerAndNotificationKey() {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        bridge.show(envelope: call(.callRinging, key: "same", peer: "phone-A"))
        bridge.show(envelope: call(.callEnded, key: "same", peer: "phone-B"))
        bridge.show(envelope: call(.callEnded, key: nil, peer: "phone-A"))
        #expect(notifications.removals.isEmpty)
        #expect(notifications.delivered["plink.call.mirrored"] != nil)
        bridge.show(envelope: call(.callEnded, key: "same", peer: "phone-A"))
        #expect(notifications.delivered.isEmpty)
    }

    @Test func mirroredCallTombstoneNeverRemovesOrReplacesHFPNotification() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        bridge.show(envelope: call(.callRinging, key: "A"))
        var hfp = MacCallSession()
        hfp.connected(phoneID: "synthetic-phone")
        hfp.ringing(number: "synthetic-caller")
        bridge.updateCall(hfp)
        let id = try #require(notifications.delivered.keys.first { $0.hasPrefix("plink.hfp.") })
        let removedBefore = notifications.removals.count
        bridge.show(envelope: call(.callEnded, key: "A"))
        bridge.show(envelope: call(.callRinging, key: "B"))
        #expect(notifications.delivered[id]?.categoryIdentifier == "plink.call.ringing")
        #expect(notifications.delivered[id]?.subtitle.isEmpty == true)
        #expect(notifications.delivered[id]?.attachments.isEmpty == true)
        #expect(notifications.delivered["plink.call.mirrored"] == nil)
        #expect(notifications.removals.count == removedBefore)
        hfp.setActive(true)
        bridge.updateCall(hfp)
        #expect(notifications.delivered[id] == nil)
        #expect(notifications.delivered.values.contains { $0.categoryIdentifier == "plink.call.active" })
    }

    @Test func clearContextsRemovesKeyedAndUnkeyedMirrorsAndRevokesIdentity() {
        let keys: [String?] = ["A", nil]
        for key in keys {
            let notifications = Notifications()
            let bridge = notifications.bridge()
            bridge.show(envelope: call(.callRinging, key: key))
            #expect(notifications.delivered["plink.call.mirrored"] != nil)
            bridge.clearContexts()
            #expect(notifications.delivered.isEmpty)
            #expect(notifications.pending.isEmpty)
            #expect(notifications.removals == [["plink.call.mirrored"]])
            bridge.show(envelope: call(.callEnded, key: key))
            #expect(notifications.removals == [["plink.call.mirrored"]])
        }
    }

    @Test func clearContextsPreservesHFPNotificationAndContext() throws {
        let notifications = Notifications()
        let bridge = notifications.bridge()
        var hfp = MacCallSession()
        hfp.connected(phoneID: "synthetic-phone")
        hfp.ringing(number: "synthetic-caller")
        bridge.updateCall(hfp)
        let id = try #require(notifications.delivered.keys.first { $0.hasPrefix("plink.hfp.") })
        bridge.clearContexts()
        #expect(notifications.delivered[id]?.categoryIdentifier == "plink.call.ringing")
        #expect(notifications.pending[id]?.categoryIdentifier == "plink.call.ringing")
        bridge.show(envelope: call(.callRinging, key: "B"))
        #expect(notifications.delivered["plink.call.mirrored"] == nil)
        hfp.setActive(true)
        bridge.updateCall(hfp)
        #expect(notifications.delivered[id] == nil)
        #expect(notifications.delivered.values.contains { $0.categoryIdentifier == "plink.call.active" })
    }

    private func call(_ type: EventType, key: String?, peer: String = "phone", caller: String = "Caller") -> PlinkEnvelope {
        var payload: [String: PayloadValue] = ["callerName": .string(caller), "packageName": .string("test.dialer")]
        if let key { payload["notificationKey"] = .string(key) }
        return PlinkEnvelope(id: UUID().uuidString, type: type, sentAt: Date(),
            sourceDeviceId: peer, targetDeviceId: "mac", payload: payload)
    }

    /// Only the OS delivery boundary is replaced; identity decisions run in NotificationBridge.
    @MainActor
    private final class Notifications {
        var delivered: [String: UNNotificationContent] = [:]
        var pending: [String: UNNotificationContent] = [:]
        var removals: [[String]] = []

        func bridge() -> NotificationBridge {
            NotificationBridge(submitNotification: { request in
                self.delivered[request.identifier] = request.content
                self.pending[request.identifier] = request.content
            }, removeNotifications: { ids in
                self.removals.append(ids)
                for id in ids {
                    self.delivered.removeValue(forKey: id)
                    self.pending.removeValue(forKey: id)
                }
            })
        }
    }
}

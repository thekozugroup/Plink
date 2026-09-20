import XCTest
@testable import PlinkCore

final class MacContinuityTests: XCTestCase {
    func testWaitingCallCannotReuseOriginalActionIdentityAfterSetupEnds() {
        var call = MacCallSession()
        call.connected(phoneID: "phone")
        call.ringing(number: "A")
        call.setActive(true)
        let original = call.context!
        call.ringing(number: "B")
        call.setupEnded()
        call.setActive(true)
        XCTAssertTrue(call.hasWaitingCall)
        for action in [MacCallAction.hangUp, .computerAudio, .phoneAudio, .toggleMute] {
            XCTAssertFalse(call.permits(action, context: original))
        }
        call.setActive(false)
        call.ringing(number: "C")
        XCTAssertNotEqual(call.context, original)
        XCTAssertTrue(call.permits(.answer, context: call.context!))
    }

    func testHeldOrDifferentCallIndexMakesTopologyAmbiguous() {
        var call = MacCallSession()
        call.connected(phoneID: "phone")
        call.observeCall(index: 1, status: 0)
        let original = call.context!
        call.observeCall(index: 2, status: 1)
        call.setupEnded()
        call.observeCall(index: 2, status: 0)
        XCTAssertFalse(call.permits(.hangUp, context: original))
    }

    func testSCOCannotCompleteAnswerOrHangup() {
        XCTAssertFalse(MacCallAction.hangUp.completesOnSCO(connected: false))
        XCTAssertFalse(MacCallAction.hangUp.completesOnSCO(connected: true))
        XCTAssertFalse(MacCallAction.answer.completesOnSCO(connected: true))
        XCTAssertTrue(MacCallAction.phoneAudio.completesOnSCO(connected: false))
        XCTAssertTrue(MacCallAction.computerAudio.completesOnSCO(connected: true))
    }
    func testCallActionsRequireCurrentIdentityAndObservedState() {
        var call = MacCallSession()
        call.connected(phoneID: "phone")
        call.ringing(number: "123")
        let first = call.context!
        XCTAssertTrue(call.begin(.answer, context: first))
        XCTAssertFalse(call.begin(.answer, context: first))
        XCTAssertEqual(call.phase, .answering)
        call.setActive(true)
        XCTAssertEqual(call.phase, .active)
        call.setSCO(true)
        XCTAssertEqual(call.audio, .scoConnectedUnverified)
        call.setActive(false)
        call.ringing(number: "456")
        XCTAssertFalse(call.begin(.hangUp, context: first))
        XCTAssertFalse(call.begin(.answer, context: first))
        XCTAssertNotEqual(call.context, first)
    }

    func testDisconnectAndCallCancellationInvalidateActions() {
        var call = MacCallSession()
        call.connected(phoneID: "phone")
        call.ringing(number: nil)
        let context = call.context!
        call.setupEnded()
        XCTAssertNil(call.context)
        XCTAssertFalse(call.begin(.decline, context: context))
        call.ringing(number: nil)
        call.disconnected()
        XCTAssertNil(call.context)
        XCTAssertEqual(call.phase, .idle)
        XCTAssertEqual(call.audio, .unavailable)
    }

    func testWaitingCallDoesNotBecomeActionableWithoutCallIndexSupport() {
        var call = MacCallSession()
        call.connected(phoneID: "phone")
        call.setActive(true)
        let context = call.context!
        call.ringing(number: "waiting")
        XCTAssertFalse(call.begin(.answer, context: context))
        XCTAssertEqual(call.phase, .active)
    }

    func testAckRequiresMatchingActionPeerAndPendingCommand() {
        var tracker = MacCommandTracker()
        let command = envelope(.mediaCommand, id: "request", payload: [:])
        tracker.begin(command, now: Date(timeIntervalSince1970: 100))
        var ack = envelope(.ack, payload: ["eventId": .string("request"), "status": .string("executed"), "action": .string("media.command")])
        ack.sourceDeviceId = "wrong"
        XCTAssertNil(tracker.resolve(ack))
        ack.sourceDeviceId = "pixel"
        ack.targetDeviceId = "mac"
        XCTAssertEqual(tracker.resolve(ack)?.status, .executed)
        XCTAssertNil(tracker.resolve(ack))
    }

    func testSocketWriteIsNotExecutionAndTimeoutIsUnknown() {
        var tracker = MacCommandTracker()
        tracker.begin(envelope(.messageReply, id: "reply", payload: [:]), now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(tracker.expire(now: Date(timeIntervalSince1970: 131)).first?.status, .unconfirmed)
        XCTAssertTrue(tracker.expire(now: Date(timeIntervalSince1970: 132)).isEmpty)
    }

    func testStatusRejectsInvalidBatteryAndMediaCommands() {
        XCTAssertNil(MacDeviceStatus(envelope: envelope(.deviceStatus, payload: ["batteryLevel": .int(101), "charging": .bool(false), "network": .string("wifi")])))
        let status = MacDeviceStatus(envelope: envelope(.deviceStatus, payload: ["batteryLevel": .int(75), "charging": .bool(true), "network": .string("wifi")]))
        XCTAssertEqual(status?.batteryLevel, 75)
        let media = MacMediaState(envelope: envelope(.mediaState, payload: ["sessionId": .string("s"), "title": .string("Song"), "artist": .string("Artist"), "playing": .bool(true), "canPlay": .bool(false), "canPause": .bool(true), "canNext": .bool(false), "canPrevious": .bool(false)]))
        XCTAssertEqual(media?.allows("pause"), true)
        XCTAssertEqual(media?.allows("next"), false)
        XCTAssertEqual(media?.allows("launch"), false)
    }

    func testReplyContextsExpireReplaceAndClear() {
        var contexts = MacReplyContexts()
        let first = ReplyContext(sourceEnvelopeId: "one", pairedDeviceId: "pixel", macDeviceId: "mac", packageName: "test", notificationKey: "key", conversationId: nil, replyToken: "a")
        var second = first
        second.replyToken = "b"
        let date = Date(timeIntervalSince1970: 100)
        contexts.store(first, notificationID: "old", now: date)
        XCTAssertEqual(contexts.store(second, notificationID: "new", now: date), ["old"])
        XCTAssertNil(contexts.take("old", now: date))
        XCTAssertNil(contexts.take("new", now: date.addingTimeInterval(601)))
        contexts.store(first, notificationID: "current", now: date)
        contexts.removeAll()
        XCTAssertNil(contexts.take("current", now: date))
    }

    func testReplyRevocationIsScopedToPeerAndNotification() {
        var contexts = MacReplyContexts()
        let first = ReplyContext(sourceEnvelopeId: "one", pairedDeviceId: "pixel", macDeviceId: "mac", packageName: "test", notificationKey: "key", conversationId: nil, replyToken: "a")
        var other = first
        other.pairedDeviceId = "other"
        contexts.store(first, notificationID: "one")
        contexts.store(other, notificationID: "two")
        XCTAssertEqual(contexts.remove(notificationKey: "key", peerID: "pixel"), ["one"])
        XCTAssertNotNil(contexts.take("two"))
    }

    func testIncorrectAckDoesNotConsumePendingCommand() {
        var tracker = MacCommandTracker()
        tracker.begin(envelope(.mediaCommand, id: "request", payload: [:]))
        var ack = envelope(.ack, payload: ["eventId": .string("request"), "status": .string("executed"), "action": .string("message.reply")])
        ack.sourceDeviceId = "pixel"; ack.targetDeviceId = "mac"
        XCTAssertNil(tracker.resolve(ack))
        ack.payload["action"] = .string("media.command")
        XCTAssertEqual(tracker.resolve(ack)?.status, .executed)
    }

    func testAwaitingUserDoesNotClaimExecutionAndAcceptsLaterOutcome() {
        var tracker = MacCommandTracker()
        tracker.begin(envelope(.clipboardUpdated, id: "clipboard", payload: [:]))
        var ack = envelope(.ack, payload: ["eventId": .string("clipboard"), "status": .string("awaiting_user"), "action": .string("clipboard.updated")])
        ack.sourceDeviceId = "pixel"; ack.targetDeviceId = "mac"
        XCTAssertEqual(tracker.resolve(ack)?.status, .awaitingUser)
        XCTAssertTrue(tracker.expire(now: Date().addingTimeInterval(31)).isEmpty)
        ack.payload["status"] = .string("executed")
        XCTAssertEqual(tracker.resolve(ack)?.status, .executed)
        XCTAssertNil(tracker.resolve(ack))
    }

    func testSCOCannotCreateCallOrGrantActions() {
        var call = MacCallSession()
        call.connected(phoneID: "phone")
        call.setSCO(true)
        XCTAssertNil(call.context)
        XCTAssertEqual(call.phase, .idle)
        call.ringing(number: "123")
        XCTAssertFalse(call.permits(.toggleMute, context: call.context!))
    }

    func testActiveRefreshDoesNotReenablePendingHangup() {
        var call = MacCallSession()
        call.connected(phoneID: "phone")
        call.setActive(true)
        let context = call.context!
        XCTAssertTrue(call.begin(.hangUp, context: context))
        call.setActive(true)
        XCTAssertEqual(call.phase, .ending)
        XCTAssertFalse(call.begin(.hangUp, context: context))
    }

    func testBluetoothDeadlineBlocksRetriesAndIgnoresLateCompletion() {
        var gate = MacBluetoothOperationGate()
        let first = gate.begin()!
        XCTAssertNil(gate.begin())
        XCTAssertFalse(gate.timeout(UUID()))
        XCTAssertTrue(gate.timeout(first))
        XCTAssertNil(gate.begin())
        XCTAssertFalse(gate.complete(first))
        XCTAssertTrue(gate.blocked)
    }

    func testBluetoothCompletionAllowsOnlyNextOperation() {
        var gate = MacBluetoothOperationGate()
        let first = gate.begin()!
        XCTAssertTrue(gate.complete(first))
        let next = gate.begin()!
        XCTAssertFalse(gate.complete(first))
        XCTAssertTrue(gate.complete(next))
    }

    private func envelope(_ type: EventType, id: String = "event", payload: [String: PayloadValue]) -> PlinkEnvelope {
        PlinkEnvelope(id: id, type: type, sentAt: .now, sourceDeviceId: "mac", targetDeviceId: "pixel", requiresAck: true, payload: payload)
    }
}

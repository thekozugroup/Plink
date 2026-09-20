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

    func testReturnedInvocationTimesOutRecoverablyAndInvalidatesCallActions() {
        var gate = MacBluetoothOperationGate()
        let generation = UUID()
        var call = activeCall()
        let context = call.context!
        let operation = gate.begin(generation: generation, action: .computerAudio, context: context)!
        XCTAssertTrue(call.begin(.computerAudio, context: context))

        XCTAssertEqual(gate.timeout(operation, invocation: .returned), .recoverable)
        XCTAssertTrue(call.markUnconfirmed(context: context))
        XCTAssertFalse(gate.blocked)
        XCTAssertNil(gate.current)
        XCTAssertFalse(call.permits(.phoneAudio, context: context))

        XCTAssertTrue(gate.requiresReconnect)
        XCTAssertNil(gate.begin(generation: UUID(), action: .hangUp, context: context))
        gate.reconnecting()
        let fresh = gate.begin(generation: UUID(), action: .hangUp, context: activeCall().context!)
        XCTAssertNotNil(fresh)
        XCTAssertEqual(gate.timeout(operation, invocation: .executing), .ignored)
        XCTAssertEqual(gate.current, fresh)
    }

    func testExecutingInvocationQuarantinesEvenAfterRemoteEnd() {
        var gate = MacBluetoothOperationGate()
        let call = activeCall()
        let operation = gate.begin(generation: UUID(), action: .phoneAudio, context: call.context!)!

        XCTAssertFalse(gate.cancelCall(operation, invocation: .executing))
        XCTAssertFalse(gate.hasCallOwnership)
        XCTAssertEqual(gate.timeout(operation, invocation: .executing), .quarantined)
        XCTAssertTrue(gate.blocked)
        XCTAssertNil(gate.begin(generation: UUID()))
        XCTAssertFalse(gate.invocationReturned(operation))
    }

    func testEveryCallActionCancelsOnTerminalStateWithoutMigratingIdentity() {
        for action in [MacCallAction.answer, .decline, .hangUp, .computerAudio, .phoneAudio] {
            var call = action == .answer || action == .decline ? ringingCall() : activeCall()
            let context = call.context!
            var gate = MacBluetoothOperationGate()
            let operation = gate.begin(generation: UUID(), action: action, context: context)!
            XCTAssertTrue(call.begin(action, context: context), action.rawValue)
            XCTAssertTrue(gate.cancelCall(operation, invocation: .returned), action.rawValue)
            call.setActive(false)
            XCTAssertNil(gate.current, action.rawValue)
            XCTAssertFalse(call.permits(action, context: context), action.rawValue)

            call.connected(phoneID: "phone")
            call.setActive(true)
            XCTAssertNotEqual(call.context, context, action.rawValue)
            XCTAssertFalse(call.permits(action, context: context), action.rawValue)
        }
    }

    func testLateOperationAndOldGenerationCannotCompleteReplacement() {
        var gate = MacBluetoothOperationGate()
        let callA = activeCall()
        let operationA = gate.begin(generation: UUID(), action: .hangUp, context: callA.context!)!
        XCTAssertTrue(gate.cancelCall(operationA, invocation: .returned))

        let callB = activeCall()
        let operationB = gate.begin(generation: UUID(), action: .hangUp, context: callB.context!)!
        XCTAssertFalse(gate.confirm(operationA, invocation: .returned))
        XCTAssertFalse(gate.invocationReturned(operationA))
        XCTAssertEqual(gate.timeout(operationA, invocation: .executing), .ignored)
        XCTAssertEqual(gate.current, operationB)
        XCTAssertFalse(gate.confirm(operationB, invocation: .executing))
        XCTAssertEqual(gate.current, operationB)
        XCTAssertTrue(gate.invocationReturned(operationB))
    }

    func testQueuedExpiredWorkNeverStartsAndReturnedCompletionCanBeDelayed() {
        let generation = UUID()
        let operation = MacBluetoothOperationGate.Operation(
            id: UUID(), generation: generation, action: nil, context: nil
        )
        var work = MacBluetoothOperationGate.WorkTracker()
        XCTAssertTrue(work.enqueue(operation))
        XCTAssertEqual(work.expire(operation), .queued)
        XCTAssertFalse(work.start(operation))

        let returned = MacBluetoothOperationGate.Operation(
            id: UUID(), generation: generation, action: nil, context: nil
        )
        XCTAssertTrue(work.enqueue(returned))
        XCTAssertTrue(work.start(returned))
        XCTAssertTrue(work.returned(returned))
        XCTAssertEqual(work.state(of: returned), .returned)
        XCTAssertTrue(work.release(returned))
    }

    func testExpiredExecutingWorkStaysQuarantinedAfterLateReturn() {
        let operation = MacBluetoothOperationGate.Operation(
            id: UUID(), generation: UUID(), action: nil, context: nil
        )
        var work = MacBluetoothOperationGate.WorkTracker()
        XCTAssertTrue(work.enqueue(operation))
        XCTAssertTrue(work.start(operation))
        XCTAssertEqual(work.expire(operation), .executing)
        XCTAssertTrue(work.quarantined)
        XCTAssertTrue(work.returned(operation))
        XCTAssertFalse(work.release(operation))
        XCTAssertFalse(work.enqueue(MacBluetoothOperationGate.Operation(
            id: UUID(), generation: UUID(), action: nil, context: nil
        )))
    }

    func testNativeContinuationIsDeniedAfterExpiryOrCancellation() {
        for expire in [true, false] {
            var gate = MacBluetoothOperationGate()
            let operation = gate.begin(generation: UUID(), action: .answer, context: ringingCall().context!)!
            var work = MacBluetoothOperationGate.WorkTracker()
            XCTAssertTrue(work.enqueue(operation))
            XCTAssertTrue(work.start(operation))
            XCTAssertTrue(work.permitsNextStep(operation))
            // The first native invocation is still executing when the deadline or call end arrives.
            if expire { XCTAssertEqual(work.expire(operation), .executing) }
            else { XCTAssertEqual(work.cancel(operation), .executing) }
            XCTAssertFalse(work.permitsNextStep(operation))
            XCTAssertTrue(work.returned(operation))
            XCTAssertFalse(work.permitsNextStep(operation))
            XCTAssertEqual(work.release(operation), !expire)
        }
    }

    func testSCOAndGenericActiveCannotResolveUnconfirmedAnswer() {
        var call = ringingCall()
        let context = call.context!
        XCTAssertTrue(call.begin(.answer, context: context))
        call.setSCO(true)
        XCTAssertEqual(call.phase, .answering)
        XCTAssertTrue(call.markUnconfirmed(context: context))
        call.setActive(true)
        XCTAssertFalse(call.stateIsCertain)
        XCTAssertFalse(call.permits(.hangUp, context: context))

        call.observeCall(index: 1, status: 0)
        XCTAssertTrue(call.stateIsCertain)
        XCTAssertNotEqual(call.context, context)
        XCTAssertTrue(call.permits(.hangUp, context: call.context!))
    }

    private func ringingCall() -> MacCallSession {
        var call = MacCallSession()
        call.connected(phoneID: "phone")
        call.ringing(number: nil)
        return call
    }

    private func activeCall() -> MacCallSession {
        var call = MacCallSession()
        call.connected(phoneID: "phone")
        call.setActive(true)
        return call
    }

    private func envelope(_ type: EventType, id: String = "event", payload: [String: PayloadValue]) -> PlinkEnvelope {
        PlinkEnvelope(id: id, type: type, sentAt: .now, sourceDeviceId: "mac", targetDeviceId: "pixel", requiresAck: true, payload: payload)
    }
}

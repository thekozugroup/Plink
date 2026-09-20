import PlinkCore
import Testing
@testable import PlinkMac

@MainActor
struct ReconnectLifecycleTests {
    @Test func restoredControllerIsInertUntilExplicitReconnect() {
        let controller = ReconnectController()
        var candidates: [ReconnectCandidate] = []
        controller.onCandidate = { candidates.append($0) }

        controller.configure(peerID: "test-pixel", pairedName: "Pixel Test")

        #expect(controller.state == .idle)
        #expect(controller.pairedName == "Pixel Test")
        #expect(candidates.isEmpty)
    }

    @Test func cancelClosesDiscoveryStateAndNotifiesLifecycleOwnerOnce() {
        let controller = ReconnectController()
        var cancellations = 0
        controller.onCancel = { cancellations += 1 }
        controller.configure(peerID: "test-pixel", pairedName: "Pixel Test")
        controller.setVerifying()

        controller.cancel()

        #expect(controller.state == .cancelled)
        #expect(cancellations == 1)
    }

    @Test func discoveryNotifiesLifecycleOwnerBeforeBrowsing() {
        let controller = ReconnectController()
        var starts = 0
        var stateAtStart: ReconnectUIState?
        controller.onDiscoveryStart = {
            starts += 1
            stateAtStart = controller.state
            return true
        }
        controller.onDiscoveredCandidates = { _ in }
        controller.configure(peerID: "test-pixel", pairedName: "Pixel Test")

        controller.beginDiscovery()

        #expect(starts == 1)
        #expect(stateAtStart == .idle)
        #expect(controller.state == .finding)
        controller.cancel()
    }

    @Test func manualReconnectRejectsNonnumericAndNonstandardPortsBeforeCallback() {
        let controller = ReconnectController()
        var callbackCount = 0
        controller.onCandidate = { _ in callbackCount += 1 }
        controller.configure(peerID: "test-pixel", pairedName: "Pixel Test")

        controller.manualIPv4 = "phone.local"
        controller.reconnectManually()
        if case .failed = controller.state {} else {
            Issue.record("Invalid manual address did not enter the failed state")
        }

        controller.manualIPv4 = "192.168.50.20:46731"
        controller.reconnectManually()
        #expect(controller.state == .failed("The reconnect port must be 45731."))
        #expect(callbackCount == 0)
    }

}

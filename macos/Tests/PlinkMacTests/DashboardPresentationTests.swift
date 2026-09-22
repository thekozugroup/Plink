import Foundation
import Testing
@testable import PlinkMac

struct DashboardPresentationTests {
    @Test(arguments: [false, true])
    func blockedCallsExplainRecoveryRegardlessOfSavedAssociation(paired: Bool) {
        #expect(DashboardPresentation.callsStatus(connected: false, paired: paired, blocked: true) == "Calls unavailable")
        #expect(DashboardPresentation.callsStatus(connected: false, paired: paired, blocked: true,
            pairedLabel: "Bluetooth paired") == "Calls unavailable")
        #expect(DashboardPresentation.callsRecoveryDetail(blocked: true) == "Restart Plink to use calls again.")
        #expect(DashboardPresentation.callsSetupDisabled(busy: false, blocked: true))
    }

    @Test func ordinaryCallPresentationAndSetupGatesRemainUnchanged() {
        #expect(DashboardPresentation.callsStatus(connected: true, paired: true, blocked: false) == "Calls connected")
        #expect(DashboardPresentation.callsStatus(connected: false, paired: true, blocked: false) == "Calls disconnected")
        #expect(DashboardPresentation.callsStatus(connected: false, paired: true, blocked: false,
            pairedLabel: "Bluetooth paired") == "Bluetooth paired")
        #expect(DashboardPresentation.callsStatus(connected: false, paired: false, blocked: false) == "Calls need setup")
        #expect(DashboardPresentation.callsRecoveryDetail(blocked: false) == nil)
        #expect(DashboardPresentation.callsSetupDisabled(busy: true, blocked: false))
        #expect(!DashboardPresentation.callsSetupDisabled(busy: false, blocked: false))
    }

    @Test func wifiConnectionDoesNotClaimCallsReady() {
        let state = DashboardPresentation(recovered: true, delayed: false, recoveryError: false,
            pairing: false, connected: true, reconnecting: false, disconnecting: false,
            hasPhone: true, bluetoothPaired: false, callsConnected: false)
        #expect(state.title == "Wi-Fi connected")
        #expect(state.primary == .setUpCalls)
        #expect(state.callsStatus == "Calls need setup")
    }

    @Test func savedBluetoothBondIsDifferentFromActiveCalls() {
        let state = DashboardPresentation(recovered: true, delayed: false, recoveryError: false,
            pairing: false, connected: true, reconnecting: false, disconnecting: false,
            hasPhone: true, bluetoothPaired: true, callsConnected: false)
        #expect(state.primary == .connectCalls)
        #expect(state.callsStatus == "Calls disconnected")
    }

    @Test func startupAndTeardownSuppressActions() {
        let delayed = DashboardPresentation(recovered: false, delayed: true, recoveryError: false,
            pairing: false, connected: false, reconnecting: false, disconnecting: false,
            hasPhone: false, bluetoothPaired: false, callsConnected: false)
        #expect(delayed.primary == nil)
        #expect(!delayed.showsProgress)
        #expect(delayed.title == "Still restoring your saved connection")
        let teardown = DashboardPresentation(recovered: true, delayed: false, recoveryError: false,
            pairing: false, connected: false, reconnecting: false, disconnecting: true,
            hasPhone: true, bluetoothPaired: true, callsConnected: false)
        #expect(teardown.primary == nil)
        #expect(teardown.title == "Disconnecting…")
    }
    @Test func primaryActionTracksPairingDiscoveryAndReadyState() {
        func state(hasPhone: Bool = true, connected: Bool = false, pairing: Bool = false,
                   reconnecting: Bool = false, error: Bool = false) -> DashboardPresentation {
            DashboardPresentation(recovered: !error, delayed: false, recoveryError: error,
                pairing: pairing, connected: connected, reconnecting: reconnecting, disconnecting: false,
                hasPhone: hasPhone, bluetoothPaired: true, callsConnected: true)
        }
        #expect(state(hasPhone: false).primary == .pair)
        #expect(state().primary == .connect)
        #expect(state(pairing: true).primary == .continuePairing)
        #expect(state(reconnecting: true).primary == .cancel)
        #expect(state(connected: true).primary == .disconnect)
        #expect(state(error: true).primary == nil)
        #expect(!state(error: true).showsProgress)
    }

}

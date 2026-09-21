import Darwin
import Foundation
import PlinkCore
import Testing
@testable import PlinkMac

@MainActor
private final class HeldCleanup {
    private var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func signalEntry() {
        entered = true
        entry?.resume()
        entry = nil
    }

    func wait() async {
        signalEntry()
        guard !released else { return }
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entry = $0 }
    }

    func release() {
        released = true
        completion?.resume()
        completion = nil
    }
}

private final class ResolvedTestService: NetService {
    private let record: Data
    private let resolvedAddresses: [Data]

    init(name: String, address: String) {
        record = NetService.data(fromTXTRecord: ["reconnect": Data("1".utf8),
            "deviceId": Data("test-phone".utf8), "platform": Data("android".utf8)])
        var socket = sockaddr_in()
        socket.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socket.sin_family = sa_family_t(AF_INET)
        socket.sin_addr.s_addr = inet_addr(address)
        resolvedAddresses = [withUnsafeBytes(of: &socket) { Data($0) }]
        super.init(domain: "local.", type: "_plink._tcp.", name: name, port: 45_731)
    }

    override var addresses: [Data]? { resolvedAddresses }
    override func txtRecordData() -> Data? { record }
}

@MainActor
struct ReconnectLifecycleTests {
    @Test(arguments: ["lock", "cancel", "pair replacement", "termination"])
    func queuedRecoveryRechecksLifecycleBeforeStarting(event: String) async throws {
        let policy = ReconnectRecoveryPolicy()
        let controller = inertController()
        var starts = 0
        controller.onDiscoveryStart = { starts += 1; return true }
        controller.onCancel = { policy.cancelByUser() }
        var unlocked = true
        var terminating = false
        var peerGeneration = UUID()
        let expectedPeer = peerGeneration
        policy.request()
        let task = try #require(policy.schedule(
            eligible: { unlocked && !terminating && peerGeneration == expectedPeer },
            connected: { false }, attempting: { false },
            start: { controller.beginDiscovery(automatically: true) }))
        // No yield until after the event: production's queued Task cannot have started.
        switch event {
        case "lock": unlocked = false
        case "cancel": controller.cancel()
        case "pair replacement": peerGeneration = UUID(); policy.invalidate()
        default: terminating = true; policy.invalidate()
        }
        await task.value
        #expect(starts == 0)
    }

    @Test func duplicateEligibleWakeQueuesOneProductionDiscovery() async throws {
        let policy = ReconnectRecoveryPolicy()
        let controller = inertController()
        var starts = 0
        controller.onDiscoveryStart = { starts += 1; return true }
        policy.request()
        let task = try #require(policy.schedule(eligible: { true }, connected: { false }, attempting: { false },
                                               start: { controller.beginDiscovery(automatically: true) }))
        let duplicate = policy.schedule(eligible: { true }, connected: { false }, attempting: { false },
                                        start: { controller.beginDiscovery(automatically: true) })
        #expect(duplicate == nil)
        await task.value
        let afterStart = policy.schedule(eligible: { true }, connected: { false }, attempting: { false },
                                         start: { controller.beginDiscovery(automatically: true) })
        #expect(afterStart == nil)
        #expect(starts == 1)
        controller.stopDiscoveryForLifecycle()
    }

    @Test(arguments: ["deadline", "cancel", "replacement"])
    func heldCleanupCannotAdmitAfterAttemptExpiresOrChanges(event: String) async throws {
        let held = HeldCleanup()
        let attemptReachedCleanup = HeldCleanup()
        let cleanup = Task { await held.wait() }
        defer { held.release() }
        await held.waitUntilEntered()
        let started = ContinuousClock.now
        let deadline = ReconnectRecoveryPolicy.attemptDeadline(from: started)
        #expect(started.duration(to: deadline) == .seconds(30))
        var now = started
        var current = true
        let (lifetime, binding) = try admissionFixture()
        let attempt = Task { () -> Bool in
            do {
                attemptReachedCleanup.signalEntry()
                try await ReconnectRecoveryPolicy.afterCleanup(cleanup, deadline: deadline,
                                                               now: { now }, isCurrent: { current })
                try ReconnectRecoveryPolicy.requireCurrent(deadline: deadline, now: now, isCurrent: current)
                _ = try lifetime.openOrdinaryAdmission(binding: binding)
                return true
            } catch { return false }
        }
        await attemptReachedCleanup.waitUntilEntered()
        switch event {
        case "deadline": now = deadline
        case "cancel": attempt.cancel()
        default: current = false
        }
        held.release()
        let admitted = await attempt.value
        #expect(!admitted)
        #expect(lifetime.ordinaryAdmission() == nil)
    }

    @Test func discoveryAndHandshakeCannotResetDeadlineAfterCleanup() async throws {
        let held = HeldCleanup()
        let attemptReachedCleanup = HeldCleanup()
        let cleanup = Task { await held.wait() }
        defer { held.release() }
        await held.waitUntilEntered()
        let started = ContinuousClock.now
        let deadline = ReconnectRecoveryPolicy.attemptDeadline(from: started)
        var now = started
        let (lifetime, binding) = try admissionFixture()
        let attempt = Task { () -> Bool in
            do {
                attemptReachedCleanup.signalEntry()
                try await ReconnectRecoveryPolicy.afterCleanup(cleanup, deadline: deadline,
                                                               now: { now }, isCurrent: { true })
                // Discovery/handshake consumes the last second; admission uses the original deadline.
                now = now.advanced(by: .seconds(2))
                try ReconnectRecoveryPolicy.requireCurrent(deadline: deadline, now: now, isCurrent: true)
                _ = try lifetime.openOrdinaryAdmission(binding: binding)
                return true
            } catch { return false }
        }
        await attemptReachedCleanup.waitUntilEntered()
        now = started.advanced(by: .seconds(29))
        held.release()
        let admitted = await attempt.value
        #expect(!admitted)
        #expect(lifetime.ordinaryAdmission() == nil)
    }

    @Test func replacedDiscoveryIgnoresOldFindResolveAndTimerCallbacks() throws {
        var browsers: [NetServiceBrowser] = []
        var resolutions: [NetService] = []
        var timeouts: [@MainActor () -> Void] = []
        var delivered: [[ReconnectCandidate]] = []
        let controller = ReconnectController(search: { browsers.append($0) },
            resolve: { resolutions.append($0) }, scheduleTimeout: { timeouts.append($0) },
            interfaces: { [Self.testInterface] })
        controller.configure(peerID: "test-phone", pairedName: "Test Phone")
        controller.onDiscoveryStart = { true }
        controller.onDiscoveredCandidates = { delivered.append($0) }
        controller.beginDiscovery()
        let oldBrowser = try #require(browsers.first)
        let oldService = ResolvedTestService(name: "old", address: "192.168.50.20")
        controller.netServiceBrowser(oldBrowser, didFind: oldService, moreComing: false)
        controller.beginDiscovery()
        let newBrowser = try #require(browsers.last)
        #expect(newBrowser !== oldBrowser)
        let newService = ResolvedTestService(name: "new", address: "192.168.50.30")
        controller.netServiceBrowser(newBrowser, didFind: newService, moreComing: false)
        controller.netServiceBrowser(oldBrowser, didFind: ResolvedTestService(name: "late", address: "192.168.50.22"), moreComing: false)
        controller.netServiceDidResolveAddress(oldService)
        controller.netService(oldService, didNotResolve: [:])
        timeouts[0]()
        #expect(controller.state == .finding)
        #expect(delivered.isEmpty)
        #expect(resolutions.count == 2)
        controller.netServiceDidResolveAddress(newService)
        timeouts[1]()
        #expect(delivered.count == 1)
        #expect(delivered.first?.map { $0.endpoint.description } == ["192.168.50.30:45731"])
        #expect(controller.state == .disconnecting)
    }

    private func inertController() -> ReconnectController {
        let controller = ReconnectController(search: { _ in }, resolve: { _ in },
                                             scheduleTimeout: { _ in }, interfaces: { [] })
        controller.configure(peerID: "test-phone", pairedName: "Test Phone")
        return controller
    }

    private static var testInterface: ReconnectInterfaceSnapshot {
        ReconnectInterfaceSnapshot(name: "test", index: 7, localIPv4: "192.168.50.10", prefixLength: 24,
                                   up: true, loopback: false, pointToPoint: false, broadcast: true, vpn: false)
    }

    private func admissionFixture() throws -> (PairSessionLifetime, VerifiedNetworkBinding) {
        let lifetime = PairSessionLifetime(localID: "mac", peerID: "phone", sessionID: "test-session",
            sessionKey: Data(repeating: 7, count: 32), stateStore: InMemoryFrameStateStore())
        let binding = VerifiedNetworkBinding(interface: Self.testInterface, localIPv4: "192.168.50.10",
            peer: try IPv4Endpoint("192.168.50.20:45731"), localListenerPort: 45_731, peerListenerPort: 45_731)
        return (lifetime, binding)
    }

    @Test func recoveryWaitsForEligibilityAndConsumesOnlyOnce() {
        let policy = ReconnectRecoveryPolicy()
        policy.request()
        let token = policy.token
        // Wake while locked/offline retains the request for a later eligible event.
        let ineligible = policy.consume(token: token, eligible: false, connected: false, attempting: false)
        #expect(!ineligible)
        #expect(policy.pending)
        let eligible = policy.consume(token: token, eligible: true, connected: false, attempting: false)
        #expect(eligible)
        // Duplicate wake/activation notifications and a failed attempt cannot rearm it.
        let duplicate = policy.consume(token: token, eligible: true, connected: false, attempting: false)
        #expect(!duplicate)
        policy.request()
        let newRequest = policy.consume(token: policy.token, eligible: true, connected: false, attempting: false)
        #expect(newRequest)
    }

    @Test func recoveryCannotReplaceHealthyConnectionOrRunningAttempt() {
        let policy = ReconnectRecoveryPolicy()
        policy.request()
        let token = policy.token
        let connected = policy.consume(token: token, eligible: true, connected: true, attempting: false)
        #expect(!connected)
        let attempting = policy.consume(token: token, eligible: true, connected: false, attempting: true)
        #expect(!attempting)
        #expect(policy.pending)
    }

    @Test func userCancelSurvivesEnvironmentChangesUntilExplicitResume() {
        let policy = ReconnectRecoveryPolicy()
        policy.request()
        let queued = policy.token
        policy.cancelByUser()
        let cancelled = policy.consume(token: queued, eligible: true, connected: false, attempting: false)
        #expect(!cancelled)
        for _ in 0..<3 {
            policy.request()
            #expect(!policy.pending)
            let suppressed = policy.consume(token: policy.token, eligible: true, connected: false, attempting: false)
            #expect(!suppressed)
        }
        policy.resumeByUser() // Explicit Connect or new pairing.
        #expect(!policy.suppressed)
        #expect(!policy.pending)
        policy.request()
        let resumed = policy.consume(token: policy.token, eligible: true, connected: false, attempting: false)
        #expect(resumed)
    }

    @Test func changedEnvironmentRejectsQueuedRecoveryFromOldGeneration() {
        let policy = ReconnectRecoveryPolicy()
        policy.request()
        let old = policy.token
        policy.request()
        let stale = policy.consume(token: old, eligible: true, connected: false, attempting: false)
        #expect(!stale)
        #expect(policy.pending)
        let current = policy.consume(token: policy.token, eligible: true, connected: false, attempting: false)
        #expect(current)
    }

    @Test func pairingOrTerminationInvalidationRejectsQueuedRecovery() {
        let policy = ReconnectRecoveryPolicy()
        policy.request()
        let old = policy.token
        policy.invalidate()
        #expect(!policy.pending)
        let invalidated = policy.consume(token: old, eligible: true, connected: false, attempting: false)
        #expect(!invalidated)
    }

    @Test func lifecycleDiscoveryStopDoesNotBecomeUserCancellation() {
        let controller = ReconnectController()
        var cancellations = 0
        var candidates = 0
        controller.onCancel = { cancellations += 1 }
        controller.onDiscoveredCandidates = { _ in candidates += 1 }
        controller.setVerifying()
        controller.stopDiscoveryForLifecycle()
        #expect(controller.state == .verifying)
        #expect(cancellations == 0)
        #expect(candidates == 0)
    }

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
        let controller = ReconnectController(search: { _ in }, resolve: { _ in },
                                             scheduleTimeout: { _ in }, interfaces: { [] })
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

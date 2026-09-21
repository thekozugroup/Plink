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

    init(name: String, address: String, peerID: String = "test-phone", port: Int32 = 45_731,
         platform: String = "android") {
        record = NetService.data(fromTXTRecord: ["reconnect": Data("1".utf8),
            "deviceId": Data(peerID.utf8), "platform": Data(platform.utf8)])
        var socket = sockaddr_in()
        socket.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socket.sin_family = sa_family_t(AF_INET)
        socket.sin_addr.s_addr = inet_addr(address)
        resolvedAddresses = [withUnsafeBytes(of: &socket) { Data($0) }]
        super.init(domain: "local.", type: "_plink._tcp.", name: name, port: port)
    }

    override var addresses: [Data]? { resolvedAddresses }
    override func txtRecordData() -> Data? { record }
}

@MainActor
private final class SelectedReturnHarness {
    var now = ContinuousClock.now
    var current = true
    var busy = false
    var browsers: [NetServiceBrowser] = []
    var resolutions: [(NetService, TimeInterval)] = []
    var queued: [@MainActor () -> Void] = []
    var starts: [(ReconnectCandidate, ContinuousClock.Instant)] = []
    var legacyStarts = 0
    var controller: ReconnectController!

    init() {
        controller = ReconnectController(search: { [unowned self] in browsers.append($0) },
            resolve: { [unowned self] in resolutions.append(($0, $1)) }, scheduleTimeout: { _ in },
            interfaces: { [ReconnectInterfaceSnapshot(name: "test", index: 7,
                localIPv4: "192.168.50.10", prefixLength: 24, up: true, loopback: false,
                pointToPoint: false, broadcast: true, vpn: false)] },
            now: { [unowned self] in now },
            enqueueObservation: { [unowned self] in queued.append($0) })
        controller.configure(peerID: "test-phone", pairedName: "Test Phone")
        controller.setConnected()
        controller.onDiscoveryStart = { [unowned self] in legacyStarts += 1; return true }
        observe()
    }

    func observe() {
        controller.observeSelectedPeer(pairKey: "test-session", epoch: UUID(), preferredEndpoint: nil,
            isCurrent: { [unowned self] in current && !busy },
            onReturn: AppDelegate.conditionalReturnHandler(isCurrent: { [unowned self] in current && !busy },
                now: { [unowned self] in now }, start: { [unowned self] candidate, deadline in
                    starts.append((candidate, deadline))
                    return true
                }))
    }

    @discardableResult
    func add(_ name: String = "phone", address: String = "192.168.50.20") -> ResolvedTestService {
        let service = ResolvedTestService(name: name, address: address)
        controller.netServiceBrowser(browsers.last!, didFind: service, moreComing: false)
        controller.netServiceDidResolveAddress(service)
        return service
    }

    func remove(_ service: NetService) {
        controller.netServiceBrowser(browsers.last!, didRemove: service, moreComing: false)
    }

    func drain() {
        let work = queued
        queued.removeAll()
        work.forEach { $0() }
    }
}

@MainActor
struct ReconnectLifecycleTests {
    @Test func selectedReturnUsesConditionalAppDispatchOnceAndPreservesConnectedState() throws {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopObservingSelectedPeer() }
        let first = harness.add()
        let second = harness.add("second")
        harness.drain()
        #expect(harness.starts.isEmpty)
        harness.remove(ResolvedTestService(name: "unrelated", address: "192.168.50.25"))
        harness.remove(first)
        harness.drain()
        #expect(harness.starts.isEmpty)
        harness.remove(second)
        #expect(harness.controller.state == .connectedInternetUnverified)
        #expect(harness.queued.isEmpty)
        let started = harness.now
        let returned = ResolvedTestService(name: "returned", address: "192.168.50.30")
        let browser = try #require(harness.browsers.last)
        harness.controller.netServiceBrowser(browser, didFind: returned, moreComing: false)
        harness.now = started.advanced(by: .seconds(1))
        harness.controller.netServiceDidResolveAddress(returned)
        harness.controller.netServiceDidResolveAddress(returned)
        harness.controller.netServiceBrowser(browser, didFind: returned, moreComing: false)
        harness.drain()
        #expect(harness.starts.count == 1)
        #expect(harness.starts.first?.0.endpoint.description == "192.168.50.30:45731")
        #expect(harness.starts.first?.1 == started.advanced(by: .seconds(30)))
        #expect(harness.legacyStarts == 0)
        #expect(harness.controller.state == .connectedInternetUnverified)
    }

    @Test func selectedReturnAcceptsEquivalentRemovalAndIgnoresDiscardedResolution() throws {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopObservingSelectedPeer() }
        let original = harness.add("phone")
        let removal = ResolvedTestService(name: "phone", address: "192.168.50.20")
        #expect(original !== removal)
        harness.remove(removal)
        #expect(original.delegate == nil) // Cleanup belongs to the retained resolver.
        #expect(harness.controller.state == .connectedInternetUnverified)
        let returned = ResolvedTestService(name: "phone", address: "192.168.50.30")
        harness.controller.netServiceBrowser(try #require(harness.browsers.last), didFind: returned, moreComing: false)
        #expect(harness.resolutions.last?.0 === returned)
        harness.controller.netServiceDidResolveAddress(original)
        harness.drain()
        #expect(harness.starts.isEmpty) // Old object cannot resolve the newly tracked return.
        harness.controller.netServiceDidResolveAddress(returned)
        harness.controller.netServiceDidResolveAddress(returned)
        harness.drain()
        #expect(harness.starts.count == 1)
        #expect(harness.starts.first?.0.endpoint.description == "192.168.50.30:45731")
        #expect(harness.legacyStarts == 0)
    }

    @Test func selectedReturnEquivalentRemovalFromOldBrowserCannotRemoveCurrentService() throws {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopObservingSelectedPeer() }
        let oldBrowser = try #require(harness.browsers.last)
        _ = harness.add("phone")
        harness.controller.stopObservingSelectedPeer()
        harness.observe()
        let current = harness.add("phone")
        let equivalent = ResolvedTestService(name: "phone", address: "192.168.50.20")
        harness.controller.netServiceBrowser(oldBrowser, didRemove: equivalent, moreComing: false)
        #expect(current.delegate != nil)
        let resolutionCount = harness.resolutions.count
        _ = harness.add("phone")
        harness.drain()
        #expect(harness.resolutions.count == resolutionCount)
        #expect(harness.starts.isEmpty)
        harness.remove(equivalent)
        _ = harness.add("phone")
        harness.drain()
        #expect(harness.starts.count == 1)
    }

    @Test(arguments: ["cancel", "lock", "pair replacement", "network change", "termination", "manual connect"], [false, true])
    func selectedReturnInvalidationDropsHeldCallbacks(reason: String, whileResolving: Bool) throws {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopDiscoveryForLifecycle() }
        let baseline = harness.add()
        harness.remove(baseline)
        let oldBrowser = try #require(harness.browsers.last)
        let returned = ResolvedTestService(name: "return", address: "192.168.50.30")
        harness.controller.netServiceBrowser(oldBrowser, didFind: returned, moreComing: false)
        #expect(harness.resolutions.last?.0 === returned)
        if !whileResolving { harness.controller.netServiceDidResolveAddress(returned) }
        #expect(harness.queued.count == (whileResolving ? 0 : 1))
        harness.current = false
        switch reason {
        case "cancel": harness.controller.cancel()
        case "pair replacement": harness.controller.configure(peerID: "test-phone", pairedName: "Replacement")
        case "manual connect": harness.controller.beginDiscovery()
        default: harness.controller.stopDiscoveryForLifecycle() // App sleep/network/termination path.
        }
        harness.current = true
        harness.observe()
        harness.controller.netServiceBrowser(oldBrowser, didFind: returned, moreComing: false)
        harness.controller.netServiceBrowser(oldBrowser, didRemove: returned, moreComing: false)
        harness.controller.netServiceDidResolveAddress(returned)
        harness.controller.netService(returned, didNotResolve: [:])
        harness.drain()
        #expect(harness.starts.isEmpty, "\(reason) invalidates old callback ownership")
        _ = harness.add("fresh-baseline")
        harness.drain()
        #expect(harness.starts.isEmpty)
        #expect(harness.legacyStarts == (reason == "manual connect" ? 1 : 0))
    }

    @Test func selectedReturnRechecksAppGateAndDropsBusyWorkWithoutRetry() {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopObservingSelectedPeer() }
        let baseline = harness.add()
        harness.remove(baseline)
        let returned = harness.add("return")
        #expect(harness.queued.count == 1)
        harness.busy = true
        harness.drain()
        harness.busy = false
        harness.now = harness.now.advanced(by: .seconds(60))
        harness.controller.netServiceDidResolveAddress(returned)
        harness.drain()
        #expect(harness.starts.isEmpty)
        harness.remove(returned)
        _ = harness.add("next-return")
        harness.drain()
        #expect(harness.starts.count == 1)
    }

    @Test func selectedReturnCooldownSurvivesObserverRestartAndHasNoTimerRetry() {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopObservingSelectedPeer() }
        let baseline = harness.add()
        harness.remove(baseline)
        _ = harness.add("return")
        harness.drain()
        #expect(harness.starts.count == 1)
        harness.controller.stopObservingSelectedPeer()
        harness.observe()
        let newBaseline = harness.add("baseline")
        harness.remove(newBaseline)
        let duringCooldown = harness.add("too-soon")
        harness.drain()
        #expect(harness.starts.count == 1)
        harness.now = harness.now.advanced(by: .seconds(30))
        harness.drain()
        #expect(harness.starts.count == 1)
        harness.remove(duringCooldown)
        _ = harness.add("later-return")
        harness.drain()
        #expect(harness.starts.count == 2)
    }

    @Test(arguments: [false, true])
    func selectedReturnOriginalDeadlineExpiresDuringResolutionOrQueuedDispatch(expireWhileResolving: Bool) throws {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopObservingSelectedPeer() }
        let baseline = harness.add()
        harness.remove(baseline)
        let returned = ResolvedTestService(name: "return", address: "192.168.50.30")
        let browser = try #require(harness.browsers.last)
        harness.controller.netServiceBrowser(browser, didFind: returned, moreComing: false)
        #expect(harness.resolutions.last?.1 == 2)
        if !expireWhileResolving { harness.controller.netServiceDidResolveAddress(returned) }
        harness.now = harness.now.advanced(by: .seconds(30))
        if expireWhileResolving { harness.controller.netServiceDidResolveAddress(returned) }
        harness.drain()
        #expect(harness.starts.isEmpty)
        #expect(harness.controller.state == .connectedInternetUnverified)
    }

    @Test(arguments: ["unrelated", "malformed", "failed"])
    func selectedReturnDeadlineBelongsToMatchingCandidate(rejected: String) throws {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopObservingSelectedPeer() }
        let baseline = harness.add()
        harness.remove(baseline)
        let browser = try #require(harness.browsers.last)
        let other = ResolvedTestService(name: "other", address: "192.168.50.21",
            peerID: rejected == "unrelated" ? "other-phone" : "test-phone",
            platform: rejected == "malformed" ? String(repeating: "x", count: 200) : "android")
        harness.controller.netServiceBrowser(browser, didFind: other, moreComing: false)
        if rejected == "failed" {
            harness.controller.netService(other, didNotResolve: [:])
        } else {
            harness.controller.netServiceDidResolveAddress(other)
        }
        harness.now = harness.now.advanced(by: .seconds(31))
        let returnedAt = harness.now
        let returned = ResolvedTestService(name: "return", address: "192.168.50.30")
        harness.controller.netServiceBrowser(browser, didFind: returned, moreComing: false)
        #expect(harness.resolutions.last?.0 === returned)
        harness.now = returnedAt.advanced(by: .seconds(1))
        harness.controller.netServiceDidResolveAddress(returned)
        harness.controller.netServiceDidResolveAddress(returned)
        harness.drain()
        #expect(harness.starts.count == 1)
        #expect(harness.starts.first?.1 == returnedAt.advanced(by: .seconds(30)))
        #expect(harness.legacyStarts == 0)
        #expect(harness.controller.state == .connectedInternetUnverified)
    }

    @Test func conditionalReturnAppDispatchRechecksEligibilityAndExactDeadline() throws {
        var now = ContinuousClock.now
        let deadline = now.advanced(by: .seconds(30))
        var eligible = false
        var starts = 0
        let handler = AppDelegate.conditionalReturnHandler(isCurrent: { eligible }, now: { now },
            start: { _, suppliedDeadline in
                #expect(suppliedDeadline == deadline)
                starts += 1
                return true
            })
        let candidate = try #require(ReconnectCandidatePolicy.candidate(endpoint: "192.168.50.20:45731",
                                                                        interface: Self.testInterface))
        #expect(!handler(candidate, deadline))
        eligible = true
        now = deadline
        #expect(!handler(candidate, deadline))
        now = deadline.advanced(by: .nanoseconds(-1))
        #expect(handler(candidate, deadline))
        #expect(starts == 1)
    }

    @Test func selectedReturnBoundsResolutionAndRejectsNonmatchingBaseline() throws {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopObservingSelectedPeer() }
        let browser = try #require(harness.browsers.last)
        let unrelated = ResolvedTestService(name: "other", address: "192.168.50.21", peerID: "other")
        harness.controller.netServiceBrowser(browser, didFind: unrelated, moreComing: false)
        harness.controller.netServiceDidResolveAddress(unrelated)
        harness.remove(unrelated)
        _ = harness.add("selected")
        harness.drain()
        #expect(harness.starts.isEmpty)
        let count = harness.resolutions.count
        for index in 0..<12 {
            let service = ResolvedTestService(name: "pending-\(index)", address: "192.168.50.22")
            harness.controller.netServiceBrowser(browser, didFind: service, moreComing: false)
        }
        #expect(harness.resolutions.count - count == 7) // One resolved + seven pending = eight.
    }

    @Test(arguments: ["wrong-peer", "wrong-port", "wrong-platform", "oversized-txt", "invalid-interface"])
    func selectedReturnRejectsUntrustedOrIneligibleResolution(fault: String) throws {
        let harness = SelectedReturnHarness()
        defer { harness.controller.stopObservingSelectedPeer() }
        let baseline = harness.add()
        harness.remove(baseline)
        let service = ResolvedTestService(name: "bad", address: fault == "invalid-interface" ? "10.1.2.3" : "192.168.50.30",
            peerID: fault == "wrong-peer" ? "other" : "test-phone", port: fault == "wrong-port" ? 1234 : 45_731,
            platform: fault == "wrong-platform" ? "other" : fault == "oversized-txt" ? String(repeating: "x", count: 200) : "android")
        harness.controller.netServiceBrowser(try #require(harness.browsers.last), didFind: service, moreComing: false)
        harness.controller.netServiceDidResolveAddress(service)
        harness.drain()
        #expect(harness.starts.isEmpty)
        #expect(harness.legacyStarts == 0)
    }

    @Test(arguments: ["cancel", "deadline", "replacement", "lock", "pair replacement", "termination"])
    func conditionalHandoffChecksRealCleanupAndNeverPublishesLate(event: String) async throws {
        let (lifetime, binding) = try admissionFixture()
        let generation = try lifetime.openOrdinaryAdmission(binding: binding)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let authority = ReconnectCommitAuthority(deadline: deadline)
        let admission = try lifetime.beginConditionalReconnect(authority: authority)
        let held = HeldCleanup()
        var now = ContinuousClock.now
        var current = true
        var retired = 0
        let handoff = ConditionalReconnectHandoff(admission: admission, authority: authority,
            deadline: deadline, now: { now }, isCurrent: { current },
            retire: { retired += 1 }, cleanup: { await held.wait() })
        #expect(lifetime.ordinaryAdmission()?.generation == generation)
        #expect(retired == 0)
        let task = Task { () -> Bool in
            do {
                try await handoff.accept()
                _ = try handoff.publish(binding: binding)
                return true
            } catch { return false }
        }
        await held.waitUntilEntered()
        #expect(retired == 1)
        var replacement: UUID?
        switch event {
        case "cancel": handoff.cancel()
        case "deadline": now = deadline
        case "replacement": replacement = try lifetime.openOrdinaryAdmission(binding: binding)
        default: current = false
        }
        held.release()
        let published = await task.value
        #expect(!published)
        handoff.cancel()
        #expect(lifetime.ordinaryAdmission()?.generation == replacement)
    }

    @Test func rejectedConditionalHandoffLeavesOrdinaryGenerationUntouched() throws {
        let (lifetime, binding) = try admissionFixture()
        let generation = try lifetime.openOrdinaryAdmission(binding: binding)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let authority = ReconnectCommitAuthority(deadline: deadline)
        let admission = try lifetime.beginConditionalReconnect(authority: authority)
        var retirements = 0
        let handoff = ConditionalReconnectHandoff(admission: admission, authority: authority,
            deadline: deadline, isCurrent: { true }, retire: { retirements += 1 }, cleanup: {})
        #expect(throws: ReconnectSessionError.self) { try handoff.publish(binding: binding) }
        handoff.cancel()
        #expect(retirements == 0)
        #expect(lifetime.ordinaryAdmission()?.generation == generation)
    }

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
            resolve: { service, _ in resolutions.append(service) }, scheduleTimeout: { timeouts.append($0) },
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
        let controller = ReconnectController(search: { _ in }, resolve: { _, _ in },
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
        let controller = ReconnectController(search: { _ in }, resolve: { _, _ in },
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

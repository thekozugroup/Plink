import Darwin
import Foundation
import OSLog
import PlinkCore

// One event-driven request per environment change; no retry timer or network authority.
@MainActor
final class ReconnectRecoveryPolicy {
    private(set) var token = UUID()
    private(set) var pending = false
    private(set) var suppressed = false
    private var queued: Task<Void, Never>?

    func invalidate() {
        queued?.cancel()
        queued = nil
        token = UUID()
        pending = false
    }

    func request() {
        invalidate()
        pending = !suppressed
    }

    func cancelByUser() {
        invalidate()
        suppressed = true
    }

    func resumeByUser() {
        invalidate()
        suppressed = false
    }

    func consume(token: UUID, eligible: Bool, connected: Bool, attempting: Bool) -> Bool {
        guard self.token == token, pending, !suppressed, eligible, !connected, !attempting else { return false }
        pending = false
        return true
    }

    @discardableResult
    func schedule(eligible: @escaping () -> Bool, connected: @escaping () -> Bool,
                  attempting: @escaping () -> Bool, start: @escaping () -> Void) -> Task<Void, Never>? {
        guard pending, queued == nil else { return nil }
        let token = token
        let task = Task { [weak self] in
            guard let self, self.token == token else { return }
            self.queued = nil
            guard !Task.isCancelled,
                  self.consume(token: token, eligible: eligible(), connected: connected(), attempting: attempting()) else { return }
            start()
        }
        queued = task
        return task
    }

    static func attemptDeadline(from now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        now.advanced(by: .seconds(30))
    }

    static func requireCurrent(deadline: ContinuousClock.Instant, now: ContinuousClock.Instant = .now,
                               isCurrent: Bool) throws {
        try Task.checkCancellation()
        guard now < deadline else { throw ReconnectSessionError.timedOut }
        guard isCurrent else { throw CancellationError() }
    }

    static func afterCleanup(_ cleanup: Task<Void, Never>?, deadline: ContinuousClock.Instant,
                             now: () -> ContinuousClock.Instant = { .now }, isCurrent: () -> Bool) async throws {
        await cleanup?.value
        try requireCurrent(deadline: deadline, now: now(), isCurrent: isCurrent())
    }
}

enum ReconnectUIState: Equatable {
    case idle
    case finding
    case verifying
    case disconnecting
    case connectedInternetUnverified
    case failed(String)
    case cancelled

    var status: String {
        switch self {
        case .idle: return "Use Reconnect after both devices join the same local network."
        case .finding: return "Finding the paired phone…"
        case .verifying: return "Verifying connection…"
        case .disconnecting: return "Finishing the previous connection…"
        case .connectedInternetUnverified: return "Connected to your phone on the local network."
        case .failed(let reason): return reason
        case .cancelled: return "Reconnect cancelled."
        }
    }
}

@MainActor
final class ReconnectController: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate,
    @preconcurrency NetServiceDelegate {
    private let observationLog = Logger(subsystem: "com.thekozugroup.plink.mac", category: "reconnect-observation")
    @Published private(set) var state: ReconnectUIState = .idle
    @Published private(set) var pairedName = "Pixel"
    @Published private(set) var currentAddresses: [String] = []
    @Published var manualIPv4 = ""

    var onDiscoveryStart: (() -> Bool)?
    var onDiscoveredCandidates: (([ReconnectCandidate]) -> Void)?
    var onCandidate: ((ReconnectCandidate) -> Void)?
    var onCancel: (() -> Void)?
    var onManualConnect: (() -> Void)?

    private var peerID = ""
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var candidates: [ReconnectCandidate] = []
    private var discovery = UUID()
    private let search: (NetServiceBrowser) -> Void
    private let resolve: (NetService, TimeInterval) -> Void
    private let scheduleTimeout: (@escaping @MainActor () -> Void) -> Void
    private let interfaces: () -> [ReconnectInterfaceSnapshot]
    private let now: () -> ContinuousClock.Instant
    private let enqueueObservation: (@escaping @MainActor () -> Void) -> Void
    private struct ObservedService {
        let service: NetService
        let returnDeadline: ContinuousClock.Instant?
        var matched = false
    }
    private var observationBrowser: NetServiceBrowser?
    private var observedServices: [ObjectIdentifier: ObservedService] = [:]
    private var observationEpoch = UUID()
    private var observationOwner: UUID?
    private var observationCurrent: (() -> Bool)?
    private var selectedReturn: ((ReconnectCandidate, ContinuousClock.Instant) -> Bool)?
    private var preferredEndpoint: String?
    private var absent = false
    private var queuedReturn: UUID?
    private var cooldownPairKey: String?
    private var lastInvocation: ContinuousClock.Instant?

    init(search: @escaping (NetServiceBrowser) -> Void = { $0.searchForServices(ofType: "_plink._tcp.", inDomain: "local.") },
         resolve: @escaping (NetService, TimeInterval) -> Void = { $0.resolve(withTimeout: $1) },
         scheduleTimeout: @escaping (@escaping @MainActor () -> Void) -> Void = { finish in
             Task { @MainActor in
                 try? await Task.sleep(for: .seconds(4))
                 finish()
             }
         },
         interfaces: @escaping () -> [ReconnectInterfaceSnapshot] = { ReconnectCandidatePolicy.currentInterfaces() },
         now: @escaping () -> ContinuousClock.Instant = { .now },
         enqueueObservation: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
             Task { @MainActor in work() }
         }) {
        self.search = search
        self.resolve = resolve
        self.scheduleTimeout = scheduleTimeout
        self.interfaces = interfaces
        self.now = now
        self.enqueueObservation = enqueueObservation
        super.init()
    }

    func configure(peerID: String, pairedName: String) {
        stopObservingSelectedPeer()
        stopDiscoveryForLifecycle()
        self.peerID = peerID
        self.pairedName = pairedName
        refreshAddresses()
        if case .connectedInternetUnverified = state { return }
        state = .idle
    }

    func beginDiscovery(automatically: Bool = false) {
        stopObservingSelectedPeer()
        if !automatically { onManualConnect?() }
        stopDiscovery()
        guard !peerID.isEmpty else { state = .failed("No active paired phone."); return }
        guard onDiscoveryStart?() == true else {
            state = .failed("No active paired phone.")
            return
        }
        discovery = UUID()
        candidates.removeAll()
        services.removeAll()
        state = .finding
        refreshAddresses()
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        search(browser)
        let token = discovery
        scheduleTimeout { [weak self] in
            guard let self, self.discovery == token, self.state == .finding else { return }
            self.finishDiscovery(token: token)
        }
    }

    func reconnectManually() {
        stopObservingSelectedPeer()
        onManualConnect?()
        stopDiscovery()
        let value = manualIPv4.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointText = value.contains(":") ? value : "\(value):45731"
        guard let endpoint = try? IPv4Endpoint(endpointText) else {
            state = .failed("Enter the phone’s IPv4 address shown in Plink.")
            return
        }
        guard endpoint.port == 45_731 else {
            state = .failed("The reconnect port must be 45731.")
            return
        }
        guard let candidate = interfaces().compactMap({
            ReconnectCandidatePolicy.candidate(endpoint: endpoint.description, interface: $0)
        }).first else {
            state = .failed("Use the phone address shown in Plink, with both devices on the same local network.")
            return
        }
        onCandidate?(candidate)
    }

    func cancel() {
        stopObservingSelectedPeer()
        stopDiscovery()
        discovery = UUID()
        state = .cancelled
        onCancel?()
    }

    func setDisconnecting() { state = .disconnecting }
    func setVerifying() { state = .verifying }
    func setConnected() { state = .connectedInternetUnverified }
    func setFailed(_ message: String) { state = .failed(message) }
    func setCancelled() { state = .cancelled }
    func setIdle() { state = .idle }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if browser === observationBrowser {
            observationLog.notice("observer.find.owned")
            guard observationCurrent?() == true else { observationLog.notice("observer.find.reject.stale"); return }
            guard observedServices.count < 8 else { observationLog.notice("observer.find.reject.capacity"); return }
            guard service.domain == "local.", service.type == "_plink._tcp." else {
                observationLog.notice("observer.find.reject.service_type"); return
            }
            guard !observedServices.values.contains(where: {
                      $0.service.name == service.name && $0.service.type == service.type && $0.service.domain == service.domain
                  }) else { observationLog.notice("observer.find.reject.duplicate"); return }
            let returnDeadline = absent ? ReconnectRecoveryPolicy.attemptDeadline(from: now()) : nil
            observedServices[ObjectIdentifier(service)] = ObservedService(service: service, returnDeadline: returnDeadline)
            service.delegate = self
            let remaining = returnDeadline.map { now().duration(to: $0) } ?? .seconds(2)
            guard remaining > .zero else {
                discardObserved(service)
                return
            }
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            resolve(service, min(2, seconds))
            return
        }
        if browser !== self.browser { observationLog.notice("observer.find.reject.stale_browser") }
        guard browser === self.browser, state == .finding, services.count < 8,
              !services.contains(where: { $0 === service }) else { return }
        services.append(service)
        service.delegate = self
        resolve(service, 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if observedServices[ObjectIdentifier(sender)] != nil {
            observationLog.notice("observer.resolve.owned")
            resolveObserved(sender)
            return
        }
        guard state == .finding, services.contains(where: { $0 === sender }) else {
            observationLog.notice("observer.resolve.reject.stale"); return
        }
        for candidate in validatedCandidates(sender) where !candidates.contains(candidate) && candidates.count < 4 {
            candidates.append(candidate)
        }
        guard candidates.count == 4 else { return }
        finishDiscovery(token: discovery)
    }

    private func validatedCandidates(_ sender: NetService) -> [ReconnectCandidate] {
        guard let txtData = sender.txtRecordData(), txtData.count <= 512 else {
            observationLog.notice("observer.resolve.reject.txt"); return []
        }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        guard txtString(txt["reconnect"]) == "1" else { observationLog.notice("observer.resolve.reject.txt"); return [] }
        guard txtString(txt["deviceId"]) == peerID else { observationLog.notice("observer.resolve.reject.peer"); return [] }
        guard txtString(txt["platform"]) == "android" else { observationLog.notice("observer.resolve.reject.platform"); return [] }
        guard sender.port == 45_731 else { observationLog.notice("observer.resolve.reject.port"); return [] }
        var result: [ReconnectCandidate] = []
        var hasIPv4 = false
        for addressData in sender.addresses ?? [] {
            guard let address = ipv4(from: addressData) else { continue }
            hasIPv4 = true
            let endpoint = "\(address):45731"
            for interface in interfaces() {
                guard let candidate = ReconnectCandidatePolicy.candidate(endpoint: endpoint, interface: interface),
                      !result.contains(candidate), result.count < 4 else { continue }
                result.append(candidate)
            }
        }
        if result.isEmpty {
            if hasIPv4 { observationLog.notice("observer.resolve.reject.address_ineligible") }
            else { observationLog.notice("observer.resolve.reject.address_no_ipv4") }
        }
        return result
    }

    // Passive presence is only a hint. This browser never enters the manual discovery state machine.
    func observeSelectedPeer(pairKey: String, epoch: UUID, preferredEndpoint: String?,
                             isCurrent: @escaping () -> Bool,
                             onReturn: @escaping (ReconnectCandidate, ContinuousClock.Instant) -> Bool) {
        guard !peerID.isEmpty else {
            observationLog.notice("observer.start.reject.peer_unconfigured")
            stopObservingSelectedPeer(); return
        }
        guard isCurrent() else {
            observationLog.notice("observer.start.reject.stale")
            stopObservingSelectedPeer(); return
        }
        if observationBrowser != nil, observationOwner == epoch, cooldownPairKey == pairKey { return }
        stopObservingSelectedPeer()
        if cooldownPairKey != pairKey { lastInvocation = nil; cooldownPairKey = pairKey }
        observationOwner = epoch
        observationCurrent = isCurrent
        selectedReturn = onReturn
        self.preferredEndpoint = preferredEndpoint
        let browser = NetServiceBrowser()
        browser.delegate = self
        observationBrowser = browser
        observationLog.notice("observer.search.start")
        search(browser)
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        if browser === observationBrowser { observationLog.notice("observer.search.will_search") }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        if browser === observationBrowser { observationLog.notice("observer.search.did_not_search") }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        if browser === observationBrowser { observationLog.notice("observer.search.did_stop_search") }
    }

    func stopObservingSelectedPeer() {
        observationEpoch = UUID()
        observationOwner = nil
        observationCurrent = nil
        selectedReturn = nil
        absent = false
        queuedReturn = nil
        let browser = observationBrowser
        observationBrowser = nil
        let services = observedServices.values.map(\.service)
        observedServices.removeAll()
        browser?.delegate = nil
        browser?.stop()
        services.forEach { $0.delegate = nil; $0.stop() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === observationBrowser else { observationLog.notice("observer.remove.reject.stale_browser"); return }
        observationLog.notice("observer.remove.owned")
        guard observationCurrent?() == true else { observationLog.notice("observer.remove.reject.stale"); return }
        guard let removed = observedServices.values.first(where: {
            $0.service.name == service.name && $0.service.type == service.type && $0.service.domain == service.domain
        }) else { observationLog.notice("observer.remove.reject.unknown"); return }
        discardObserved(removed.service)
        guard removed.matched, !observedServices.values.contains(where: \.matched) else { return }
        absent = true
        queuedReturn = nil
        observationLog.notice("observer.remove.selected_absent")
    }

    private func discardObserved(_ service: NetService) {
        observedServices.removeValue(forKey: ObjectIdentifier(service))
        service.delegate = nil
        service.stop()
    }

    private func resolveObserved(_ service: NetService) {
        let id = ObjectIdentifier(service)
        guard observationCurrent?() == true else { observationLog.notice("observer.resolve.reject.stale"); return }
        guard observedServices[id]?.matched == false else { observationLog.notice("observer.resolve.reject.duplicate"); return }
        let candidates = validatedCandidates(service).sorted {
            if ($0.endpoint.description == preferredEndpoint) != ($1.endpoint.description == preferredEndpoint) {
                return $0.endpoint.description == preferredEndpoint
            }
            if $0.endpoint.description != $1.endpoint.description { return $0.endpoint.description < $1.endpoint.description }
            return $0.interface.name < $1.interface.name
        }
        guard let candidate = candidates.first else { discardObserved(service); return }
        observationLog.notice("observer.resolve.accepted")
        observedServices[id]?.matched = true
        guard absent else {
            NSLog("Plink selected peer observation established")
            return // Initial matching Add is baseline, never a reconnect.
        }
        absent = false
        let deadline = observedServices[id]?.returnDeadline
        guard let deadline, now() < deadline, queuedReturn == nil,
              lastInvocation.map({ now() >= $0.advanced(by: .seconds(30)) }) ?? true else { return }
        let token = UUID()
        let epoch = observationEpoch
        queuedReturn = token
        enqueueObservation { [weak self] in
            guard let self, self.observationEpoch == epoch, self.queuedReturn == token else { return }
            self.queuedReturn = nil
            guard self.observationCurrent?() == true, self.observedServices[id]?.matched == true,
                  self.now() < deadline, self.interfaces().contains(candidate.interface),
                  self.lastInvocation.map({ self.now() >= $0.advanced(by: .seconds(30)) }) ?? true else { return }
            if self.selectedReturn?(candidate, deadline) == true {
                self.lastInvocation = self.now()
                observationLog.notice("Plink selected peer return started conditional reconnect")
            }
        }
    }

    private func finishDiscovery(token: UUID) {
        guard discovery == token, state == .finding else { return }
        let discovered = candidates
        discovery = UUID()
        stopDiscovery()
        state = .disconnecting
        guard !discovered.isEmpty else {
            onDiscoveredCandidates?([])
            return
        }
        onDiscoveredCandidates?(discovered)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        if observedServices[ObjectIdentifier(sender)] != nil {
            observationLog.notice("observer.resolve.did_not_resolve")
            discardObserved(sender); return
        }
        guard services.contains(where: { $0 === sender }) else { return }
        services.removeAll { $0 === sender }
        sender.delegate = nil
        sender.stop()
    }

    func stopDiscoveryForLifecycle() {
        stopObservingSelectedPeer()
        stopDiscovery()
    }

    private func stopDiscovery() {
        discovery = UUID()
        let previousBrowser = browser
        let previousServices = services
        browser = nil
        services.removeAll()
        candidates.removeAll()
        previousBrowser?.delegate = nil
        previousBrowser?.stop()
        previousServices.forEach { $0.delegate = nil; $0.stop() }
    }

    private func refreshAddresses() {
        currentAddresses = interfaces()
            .filter { $0.up && $0.broadcast && !$0.loopback && !$0.pointToPoint && !$0.vpn }
            .map(\.localIPv4).sorted()
    }

    private func txtString(_ data: Data?) -> String? {
        guard let data, data.count <= 128 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func ipv4(from data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            let address = base.assumingMemoryBound(to: sockaddr_in.self).pointee
            guard address.sin_family == sa_family_t(AF_INET) else { return nil }
            var source = address.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &source, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}

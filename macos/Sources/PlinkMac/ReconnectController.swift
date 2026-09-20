import Darwin
import Foundation
import PlinkCore

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
    @Published private(set) var state: ReconnectUIState = .idle
    @Published private(set) var pairedName = "Pixel"
    @Published private(set) var currentAddresses: [String] = []
    @Published var manualIPv4 = ""

    var onDiscoveryStart: (() -> Bool)?
    var onDiscoveredCandidates: (([ReconnectCandidate]) -> Void)?
    var onCandidate: ((ReconnectCandidate) -> Void)?
    var onCancel: (() -> Void)?

    private var peerID = ""
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var candidates: [ReconnectCandidate] = []
    private var discovery = UUID()

    func configure(peerID: String, pairedName: String) {
        self.peerID = peerID
        self.pairedName = pairedName
        refreshAddresses()
        if case .connectedInternetUnverified = state { return }
        state = .idle
    }

    func beginDiscovery() {
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
        browser.searchForServices(ofType: "_plink._tcp.", inDomain: "local.")
        let token = discovery
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.discovery == token, self.state == .finding else { return }
            self.finishDiscovery(token: token)
        }
    }

    func reconnectManually() {
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
        guard let candidate = ReconnectCandidatePolicy.currentInterfaces().compactMap({
            ReconnectCandidatePolicy.candidate(endpoint: endpoint.description, interface: $0)
        }).first else {
            state = .failed("Use the phone address shown in Plink, with both devices on the same local network.")
            return
        }
        onCandidate?(candidate)
    }

    func cancel() {
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
        guard state == .finding, services.count < 8 else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard state == .finding, let txtData = sender.txtRecordData(), txtData.count <= 512 else { return }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        guard txtString(txt["reconnect"]) == "1", txtString(txt["deviceId"]) == peerID,
              txtString(txt["platform"]) == "android", sender.port == 45_731 else { return }
        for addressData in sender.addresses ?? [] {
            guard let address = ipv4(from: addressData) else { continue }
            let endpoint = "\(address):45731"
            for interface in ReconnectCandidatePolicy.currentInterfaces() {
                guard let candidate = ReconnectCandidatePolicy.candidate(endpoint: endpoint, interface: interface),
                      !candidates.contains(candidate), candidates.count < 4 else { continue }
                candidates.append(candidate)
            }
        }
        guard candidates.count == 4 else { return }
        finishDiscovery(token: discovery)
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
        services.removeAll { $0 === sender }
    }

    private func stopDiscovery() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        services.forEach { $0.stop(); $0.delegate = nil }
        services.removeAll()
    }

    private func refreshAddresses() {
        currentAddresses = ReconnectCandidatePolicy.currentInterfaces()
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

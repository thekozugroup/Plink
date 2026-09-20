import CryptoKit
import Foundation
import PlinkCore

enum ReconnectRoundtripError: Error {
    case invalidEnvironment(String)
    case missingLoopbackInterface
    case invalidCandidate
    case unexpectedHint
    case ordinaryProbeFailed
    case reportValidationFailed
}

private final class RecordingFrameStateStore: FrameStateStoring, @unchecked Sendable {
    private let store: FileFrameStateStore
    private let lock = NSLock()
    private var highestReserved: Int64 = 0

    init(directory: URL) {
        store = FileFrameStateStore(directory: directory)
    }

    func reserveSequence(scope: String) throws -> Int64 {
        let sequence = try store.reserveSequence(scope: scope)
        lock.withLock { highestReserved = max(highestReserved, sequence) }
        return sequence
    }

    func accept(scope: String, sequence: Int64, nonce: String) throws {
        try store.accept(scope: scope, sequence: sequence, nonce: nonce)
    }

    var highestReservedSequence: Int64 { lock.withLock { highestReserved } }
}

private final class OrdinaryProbeObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedGeneration: UUID?
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var count = 0

    func setExpectedGeneration(_ generation: UUID) {
        lock.withLock { expectedGeneration = generation }
    }

    func receive(_ incoming: Result<PlinkEnvelope, any Error>, generation: UUID) {
        do {
            let envelope = try incoming.get()
            let expected = lock.withLock { expectedGeneration }
            guard expected == generation,
                  envelope.type == .deviceStatus,
                  envelope.sourceDeviceId == "test-pixel",
                  envelope.targetDeviceId == "test-mac",
                  envelope.requiresAck == false,
                  envelope.payload == ["batteryLevel": .int(53)] else {
                throw ReconnectRoundtripError.ordinaryProbeFailed
            }
            resolve(.success(()), received: true)
        } catch {
            resolve(.failure(error), received: false)
        }
    }

    func wait(timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let existing = lock.withLock { () -> Result<Void, any Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let existing { continuation.resume(with: existing) }
                else {
                    Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        self?.resolve(.failure(ReconnectSessionError.timedOut), received: false)
                    }
                }
            }
        } onCancel: {
            resolve(.failure(ReconnectSessionError.cancelled), received: false)
        }
    }

    var receivedCount: Int { lock.withLock { count } }

    private func resolve(_ value: Result<Void, any Error>, received: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard result == nil else { return nil }
            result = value
            if received { count += 1 }
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: value)
    }
}

private struct ReconnectMacReport: Codable {
    struct SocketObservation: Codable {
        let channel: String
        let localHost: String
        let localPort: Int
        let remoteHost: String
        let remotePort: Int
    }

    let schemaVersion: Int
    let runId: String
    let phase: String
    let role: String
    let passed: Bool
    let proofIdHash: String
    let hintBefore: String?
    let hintAfter: String
    let ordinarySent: Int
    let ordinaryReceived: Int
    let ordinaryAdmissionInitiallyClosed: Bool
    let highestReservedSequence: Int64
    let socketObservations: [SocketObservation]
    let cleanupComplete: Bool

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(runId, forKey: .runId)
        try values.encode(phase, forKey: .phase)
        try values.encode(role, forKey: .role)
        try values.encode(passed, forKey: .passed)
        try values.encode(proofIdHash, forKey: .proofIdHash)
        if let hintBefore { try values.encode(hintBefore, forKey: .hintBefore) }
        else { try values.encodeNil(forKey: .hintBefore) }
        try values.encode(hintAfter, forKey: .hintAfter)
        try values.encode(ordinarySent, forKey: .ordinarySent)
        try values.encode(ordinaryReceived, forKey: .ordinaryReceived)
        try values.encode(ordinaryAdmissionInitiallyClosed, forKey: .ordinaryAdmissionInitiallyClosed)
        try values.encode(highestReservedSequence, forKey: .highestReservedSequence)
        try values.encode(socketObservations, forKey: .socketObservations)
        try values.encode(cleanupComplete, forKey: .cleanupComplete)
    }
}

enum ReconnectRoundtrip {
    static func run(
        sessionKey: Data,
        pairedDeviceID: String,
        targetDeviceID: String,
        receiverPort: UInt16,
        replyPort: UInt16
    ) async throws {
        guard pairedDeviceID == "test-pixel", targetDeviceID == "test-mac",
              receiverPort > 0, replyPort > 0, sessionKey.count == 32 else {
            throw ReconnectRoundtripError.invalidEnvironment("isolated identities and ports")
        }
        let evidencePath = try environment("PLINK_DEBUG_RECONNECT_EVIDENCE_DIR")
        let statePath = try environment("PLINK_DEBUG_RECONNECT_STATE_DIR")
        guard evidencePath.hasPrefix("/"), statePath.hasPrefix("/") else {
            throw ReconnectRoundtripError.invalidEnvironment("absolute state and evidence paths")
        }
        let evidenceDirectory = URL(fileURLWithPath: evidencePath, isDirectory: true)
        let stateDirectory = URL(fileURLWithPath: statePath, isDirectory: true)
        let runID = try environment("PLINK_DEBUG_RECONNECT_RUN_ID")
        let phase = try environment("PLINK_DEBUG_RECONNECT_PHASE")
        try validate(runID: runID, phase: phase, receiverPort: receiverPort, replyPort: replyPort)

        let validation = ReconnectValidationPolicy(
            allowedPorts: [receiverPort, replyPort],
            allowsLoopback: true
        )
        guard let loopback = ReconnectCandidatePolicy.currentInterfaces().first(where: {
            $0.loopback && $0.localIPv4 == "127.0.0.1"
        }) else { throw ReconnectRoundtripError.missingLoopbackInterface }
        guard let candidate = ReconnectCandidatePolicy.candidate(
            endpoint: "127.0.0.1:\(replyPort)",
            interface: loopback,
            validation: validation
        ) else { throw ReconnectRoundtripError.invalidCandidate }

        let frameStore = RecordingFrameStateStore(directory: stateDirectory.appendingPathComponent("frame-state"))
        let endpointStore = ReconnectEndpointStore(directory: stateDirectory.appendingPathComponent("endpoints"))
        let sessionID = "debug-reconnect-\(runID)"
        let storedBefore = try endpointStore.load(localID: targetDeviceID, peerID: pairedDeviceID,
            sessionID: sessionID, sessionKey: sessionKey)
        let hintBefore = storedBefore?.endpoint
        let priorProofFile = stateDirectory.appendingPathComponent("previous-proof.sha256")
        if phase == "A" {
            guard !FileManager.default.fileExists(atPath: priorProofFile.path) else {
                throw ReconnectRoundtripError.unexpectedHint
            }
        } else {
            guard let storedBefore,
                  try String(contentsOf: priorProofFile, encoding: .utf8) == sha256(storedBefore.proofID) else {
                throw ReconnectRoundtripError.unexpectedHint
            }
        }
        try validateHintBefore(hintBefore, phase: phase, currentEndpoint: candidate.endpoint.description)

        let lifetime = PairSessionLifetime(localID: targetDeviceID, peerID: pairedDeviceID,
            sessionID: sessionID, sessionKey: sessionKey, stateStore: frameStore, validation: validation)
        let admissionInitiallyClosed = lifetime.ordinaryAdmission() == nil
        let probe = OrdinaryProbeObserver()
        let listener = ReconnectListener(port: receiverPort, bindAddress: "127.0.0.1", lifetime: lifetime) {
            probe.receive($0, generation: $1)
        }
        let authority = ReconnectCommitAuthority()
        var sender: SerializedPlinkSender?
        var ordinarySent = 0
        var cleanupComplete = false

        do {
            try listener.start()
            let result = try await ReconnectInitiator(lifetime: lifetime, listener: listener,
                commitAuthority: authority,
                endpointStore: endpointStore, listenerPort: receiverPort).attempt(candidate: candidate)
            let generation = try lifetime.openOrdinaryAdmission(binding: result.binding)
            probe.setExpectedGeneration(generation)
            let activeSender = SerializedPlinkSender(transport: BoundSecureNetworkPlinkClient(
                lifetime: lifetime, binding: result.binding, generation: generation))
            sender = activeSender
            let ordinary = PlinkEnvelope(id: UUID().uuidString.lowercased(), type: .deviceStatus, sentAt: .now,
                sourceDeviceId: targetDeviceID, targetDeviceId: pairedDeviceID,
                requiresAck: false, payload: ["batteryLevel": .int(53)])
            try await activeSender.send(ordinary)
            ordinarySent += 1
            try await probe.wait(timeout: 10)

            await activeSender.shutdown()
            sender = nil
            lifetime.closeOrdinaryAdmission()
            listener.stop()
            lifetime.invalidate()
            authority.invalidate()
            cleanupComplete = true

            let storedAfter = try endpointStore.load(localID: targetDeviceID, peerID: pairedDeviceID,
                sessionID: sessionID, sessionKey: sessionKey)
            guard let storedAfter, storedAfter.proofID == result.proofID,
                  admissionInitiallyClosed, ordinarySent == 1, probe.receivedCount == 1,
                  frameStore.highestReservedSequence > 0,
                  storedAfter.endpoint == candidate.endpoint.description, cleanupComplete,
                  result.observedOutbound.local.address == loopback.localIPv4,
                  result.observedOutbound.local.port > 0,
                  result.observedOutbound.remote == candidate.endpoint,
                  result.observedReverse.local == (try IPv4Endpoint(address: loopback.localIPv4,
                                                                    port: receiverPort)),
                  result.observedReverse.remote.address == candidate.endpoint.address,
                  result.observedReverse.remote.port > 0 else {
                throw ReconnectRoundtripError.reportValidationFailed
            }
            let report = ReconnectMacReport(schemaVersion: 1, runId: runID, phase: phase, role: "mac",
                passed: true, proofIdHash: sha256(result.proofID), hintBefore: hintBefore,
                hintAfter: storedAfter.endpoint, ordinarySent: ordinarySent, ordinaryReceived: probe.receivedCount,
                ordinaryAdmissionInitiallyClosed: admissionInitiallyClosed,
                highestReservedSequence: frameStore.highestReservedSequence,
                socketObservations: [reportObservation("C1", result.observedOutbound),
                    reportObservation("C2", result.observedReverse)], cleanupComplete: cleanupComplete)
            try sha256(result.proofID).write(to: priorProofFile, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(to: evidenceDirectory.appendingPathComponent("reconnect-mac.json"),
                options: .atomic)
            print("RECONNECT MAC PASSED")
        } catch {
            sender?.invalidate()
            await sender?.shutdown()
            lifetime.closeOrdinaryAdmission()
            authority.invalidate()
            listener.stop()
            lifetime.invalidate()
            throw error
        }
    }

    private static func validate(
        runID: String,
        phase: String,
        receiverPort: UInt16,
        replyPort: UInt16
    ) throws {
        guard let uuid = UUID(uuidString: runID), uuid.uuidString.lowercased() == runID,
              runID[runID.index(runID.startIndex, offsetBy: 14)] == "4",
              "89ab".contains(runID[runID.index(runID.startIndex, offsetBy: 19)]),
              ["A", "B", "B-restart"].contains(phase) else {
            throw ReconnectRoundtripError.invalidEnvironment("run id or phase")
        }
        let expectedPorts: (receiver: UInt16, reply: UInt16) = phase == "A"
            ? (46_732, 46_731) : (46_742, 46_741)
        guard receiverPort == expectedPorts.receiver, replyPort == expectedPorts.reply else {
            throw ReconnectRoundtripError.invalidEnvironment("phase ports")
        }
    }

    private static func validateHintBefore(_ hint: String?, phase: String, currentEndpoint: String) throws {
        switch phase {
        case "A":
            guard hint == nil else { throw ReconnectRoundtripError.unexpectedHint }
        case "B":
            guard hint == "127.0.0.1:46731", hint != currentEndpoint else {
                throw ReconnectRoundtripError.unexpectedHint
            }
        case "B-restart":
            guard hint == currentEndpoint else { throw ReconnectRoundtripError.unexpectedHint }
        default:
            throw ReconnectRoundtripError.unexpectedHint
        }
    }

    private static func reportObservation(
        _ channel: String,
        _ observation: ReconnectSocketObservation
    ) -> ReconnectMacReport.SocketObservation {
        ReconnectMacReport.SocketObservation(channel: channel,
            localHost: observation.local.address, localPort: Int(observation.local.port),
            remoteHost: observation.remote.address, remotePort: Int(observation.remote.port))
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

import CoreGraphics
import Foundation
import PlinkCore

/// Exercises normal Android consent/capture and native decode using isolated identities.
/// This driver never claims native Mac window or physical Pixel verification.
final class ScreenRoundtripHarness: @unchecked Sendable {
    private let stream: AsyncStream<PlinkEnvelope>
    private let continuation: AsyncStream<PlinkEnvelope>.Continuation
    private let client: SerializedPlinkSender
    private let decoder = ScreenFrameDecoder()
    private let evidenceDirectory: URL
    private let finish: @Sendable (Bool) -> Void
    private var worker: Task<Void, Never>?
    private let stopped = DispatchSemaphore(value: 0)

    init(codec: EncryptedFrameCodec, frameState: InMemoryFrameStateStore, replyPort: UInt16,
         evidenceDirectory: URL,
         finish: @escaping @Sendable (Bool) -> Void) {
        let pair = AsyncStream<PlinkEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(2))
        stream = pair.stream; continuation = pair.continuation
        client = SerializedPlinkSender(transport: SecureNetworkPlinkClient(
            host: "127.0.0.1", port: replyPort, codec: codec, stateStore: frameState))
        self.evidenceDirectory = evidenceDirectory; self.finish = finish
    }

    func start() {
        worker = Task { [self] in
            var passed = false
            defer { finish(passed); stopped.signal() }
            do {
                var requested = false, stopping = false
                var session = ScreenPreviewSession(binding: ScreenPreviewBinding(localDeviceID: "test-mac", peerDeviceID: "test-pixel"))
                var patternFrames = 0, totalFrames = 0
                var hashes = Set<String>(), markers = Set<String>()
                let startedAt = ProcessInfo.processInfo.systemUptime
                var firstPatternAt: TimeInterval?, lastPatternAt: TimeInterval?
                var minimumPatternInterval: TimeInterval?, maximumJPEGBytes = 0
                for await event in stream {
                    try Task.checkCancellation()
                    if event.type == .ack && event.payload["eventId"]?.stringValue == "screen-test-ready" {
                        guard !requested else { throw failure("Repeated synthetic readiness") }
                        requested = true
                        try await send(session.start())
                        print("screen: normal OS consent requested on isolated emulator")
                        continue
                    }
                    if event.type == .ack && event.payload["eventId"]?.stringValue == "screen-test-stopped" {
                        guard stopping, patternFrames >= 6, hashes.count >= 3, markers.count >= 2 else {
                            throw failure("Stop acknowledgment before verified changing pixels")
                        }
                        let summary: [String: Any] = [
                            "passed": true, "mode": "synthetic-owned-emulator",
                            "scope": "pixel and transport sub-result; host final-result.json decides cleanup and aggregate success",
                            "capturedPatternFrames": patternFrames, "decodedFrames": totalFrames,
                            "distinctPixelHashes": hashes.count, "distinctMarkerObservations": markers.count,
                            "maximumJPEGBytes": maximumJPEGBytes,
                            "secondsToFirstPattern": firstPatternAt.map { $0 - startedAt } ?? 0,
                            "minimumPatternDecodeIntervalSeconds": minimumPatternInterval ?? 0,
                            "productionDecoder": "ScreenFrameDecoder ImageIO",
                            "productionSession": "ScreenPreviewSession",
                            "androidStopAcknowledged": true,
                            "nativeMacWindowVerified": false, "physicalPixelVerified": false,
                        ]
                        let summaryURL = evidenceDirectory.appendingPathComponent("summary.json")
                        guard !FileManager.default.fileExists(atPath: summaryURL.path) else {
                            throw failure("Refusing to replace screen summary")
                        }
                        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                            .write(to: summaryURL, options: .atomic)
                        print("SCREEN ROUNDTRIP PASSED: actual MediaProjection, encrypted transport, native ImageIO; \(patternFrames) pattern frames, \(hashes.count) distinct decoded pixel hashes, Android stop acknowledged")
                        passed = true; break
                    }
                    guard requested, !stopping else { throw failure("Unexpected event outside active capture") }
                    let update = try session.receive(event)
                    guard !update.ignored, !update.ended else { throw failure("Production session rejected the screen event") }
                    try await send(update)
                    if session.phase == .needsConsent {
                        print("screen: awaiting explicit Plink Share action and Android consent")
                    }
                    if let frameEnvelope = update.frameEnvelope, let ticket = update.frameTicket {
                        let decoded = try await decoder.decode(frameEnvelope)
                        let image = decoded.image
                        let presented = session.completePresentation(decoded, ticket: ticket)
                        guard !presented.ended, !presented.ignored else { throw failure("Production session rejected decoded frame") }
                        try await send(presented)
                        guard case .frame(let payload) = try ScreenPreviewMessage(envelope: frameEnvelope) else {
                            throw failure("Missing frame payload")
                        }
                        let width = decoded.width, height = decoded.height, bytes = payload.jpegData
                        totalFrames += 1
                        maximumJPEGBytes = max(maximumJPEGBytes, bytes.count)
                        if let observation = try ScreenPatternVerifier.inspect(image) {
                            let now = ProcessInfo.processInfo.systemUptime
                            if firstPatternAt == nil { firstPatternAt = now }
                            if let lastPatternAt {
                                minimumPatternInterval = min(minimumPatternInterval ?? .infinity, now - lastPatternAt)
                            }
                            lastPatternAt = now
                            patternFrames += 1
                            hashes.insert(observation.pixelSHA256)
                            markers.insert("\(observation.markerIsMagenta)-\(observation.markerColumn / 8)")
                            print("screen: decoded pattern=\(patternFrames) dimensions=\(width)x\(height) jpegBytes=\(bytes.count) pixelSHA256=\(observation.pixelSHA256)")
                            if patternFrames == 1 || patternFrames == 6 {
                                try ScreenPatternVerifier.saveEvidence(image,
                                    to: evidenceDirectory.appendingPathComponent("decoded-pattern-\(patternFrames).png"))
                            }
                        }
                        if totalFrames > 30 { throw failure("Synthetic pattern never stabilized") }
                    }
                    guard event.type == .screenFrame || event.type == .screenIdle else { continue }
                    if patternFrames >= 6 && hashes.count >= 3 && markers.count >= 2 {
                        stopping = true
                        try await send(session.stop(reason: .user))
                        print("screen: changing pixels verified; waiting for Android cleanup acknowledgment")
                    } else {
                        // Wait after response/decode completion, matching production pacing.
                        try await Task.sleep(for: .milliseconds(550))
                        while true {
                            let next = session.wake()
                            guard !next.ended else { throw failure("Production session timed out") }
                            try await send(next)
                            if !next.outgoing.isEmpty { break }
                            guard let deadline = session.nextWakeInstant else {
                                throw failure("Production session lost its next pull")
                            }
                            try await ContinuousClock().sleep(until: deadline)
                        }
                    }
                }
            } catch { fputs("Screen roundtrip failed: \(error)\n", stderr) }
            await client.shutdown()
        }
    }

    func receive(_ event: PlinkEnvelope) {
        if case .dropped = continuation.yield(event) { finish(false) }
    }

    func stop() {
        continuation.finish(); worker?.cancel()
        if stopped.wait(timeout: .now() + 5) == .timedOut {
            fputs("Screen roundtrip worker did not finish\n", stderr); finish(false)
        }
    }

    private func send(_ update: ScreenPreviewSessionUpdate) async throws {
        for envelope in update.outgoing { try await client.send(envelope) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "PlinkScreenRoundtrip", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

import Foundation
import CryptoKit
import PlinkCore

/// Isolated synthetic integration driver. It exercises the production engine and
/// encrypted socket transport; it does not substitute for native picker consent.
final class FileRoundtripHarness: @unchecked Sendable {
    private let stream: AsyncStream<PlinkEnvelope>
    private let continuation: AsyncStream<PlinkEnvelope>.Continuation
    private let root: URL
    private let engine: MacFileTransfer
    private let client: SecureNetworkPlinkClient
    private var worker: Task<Void, Never>?
    private let stopped = DispatchSemaphore(value: 0)
    private let finish: @Sendable (Bool) -> Void
    private static let sizes = [0, 1, 32_768, 32_769, 16_777_216]

    init(codec: EncryptedFrameCodec, frameState: InMemoryFrameStateStore, replyPort: UInt16,
         finish: @escaping @Sendable (Bool) -> Void) {
        let pair = AsyncStream<PlinkEnvelope>.makeStream(bufferingPolicy: .bufferingOldest(4))
        stream = pair.stream; continuation = pair.continuation
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plink-file-roundtrip-\(UUID().uuidString)")
        engine = MacFileTransfer(localID: "test-mac", peerID: "test-pixel", root: root.appendingPathComponent("stage"))
        client = SecureNetworkPlinkClient(host: "127.0.0.1", port: replyPort, codec: codec, stateStore: frameState)
        self.finish = finish
    }

    func start() {
        worker = Task { [self] in
            var passed = false
            defer {
                do { try FileManager.default.removeItem(at: root) }
                catch { passed = false; fputs("File roundtrip cleanup failed: \(error)\n", stderr) }
                finish(passed)
                stopped.signal()
            }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                _ = await engine.setReceivingEnabled(true)
                var completed = 0
                var returningFile = false
                for await event in stream {
                    try Task.checkCancellation()
                    guard completed < Self.sizes.count, FileTransferPayloadPolicy.eventTypes.contains(event.type) else {
                        throw failure("Unexpected event")
                    }
                    let destination = root.appendingPathComponent("boundary-\(Self.sizes[completed]).bin")
                    var update = await engine.receive(event)
                    if update.state.canAccept {
                        guard !returningFile, update.state.size == Self.sizes[completed], let id = update.state.transferID else {
                            throw failure("Unexpected file offer")
                        }
                        update = await engine.accept(transferID: id, destination: destination)
                    }
                    for outbound in update.outgoing { try await client.send(outbound) }
                    guard ![.failed, .cancelled, .unconfirmed].contains(update.state.phase) else {
                        throw failure(update.state.detail)
                    }
                    if update.state.phase == .saved {
                        if returningFile {
                            print("FILE ROUNDTRIP boundary=\(Self.sizes[completed]) Android and Mac saved; SHA-256 checked")
                            try FileManager.default.removeItem(at: destination)
                            completed += 1; returningFile = false
                            if completed == Self.sizes.count {
                                print("FILE ROUNDTRIP PASSED: 10 encrypted transfers; 0, 1, 32768, 32769, 16777216 bytes; real file IO and cleanup")
                                passed = true; return
                            }
                        } else {
                            let bytes = try Data(contentsOf: destination)
                            guard bytes.count == Self.sizes[completed], bytes.enumerated().allSatisfy({ $0.element == UInt8($0.offset % 251) }) else {
                                throw failure("Saved bytes differ from synthetic fixture")
                            }
                            print("Mac saved bytes=\(bytes.count) sha256=\(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())")
                            guard try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("stage").path).isEmpty else {
                                throw failure("Receive staging was not cleaned")
                            }
                            returningFile = true
                            let offered = try await engine.prepareSend(source: destination)
                            for outbound in offered.outgoing { try await client.send(outbound) }
                        }
                    }
                }
            } catch {
                fputs("File roundtrip failed: \(error)\n", stderr)
            }
        }
    }

    func receive(_ event: PlinkEnvelope) {
        if case .dropped = continuation.yield(event) { finish(false) }
    }

    func stop() {
        continuation.finish(); worker?.cancel()
        if stopped.wait(timeout: .now() + 5) == .timedOut {
            fputs("File roundtrip worker did not finish cleanup\n", stderr)
            finish(false)
        }
    }

    private func failure(_ text: String) -> NSError { NSError(domain: "PlinkFileRoundtrip", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

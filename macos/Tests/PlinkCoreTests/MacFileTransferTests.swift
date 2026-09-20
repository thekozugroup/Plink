import XCTest
import CryptoKit
@testable import PlinkCore

final class MacFileTransferTests: XCTestCase, @unchecked Sendable {
    func testDeferredChooserCannotCancelReplacementOffer() {
        var chooser = MacFileChooserOwnership()
        let generation = UUID()
        let old = chooser.begin(generation: generation, transferID: "A")
        // Timeout invalidates ownership before AppKit receives programmatic cancel.
        chooser.invalidate()
        let current = chooser.begin(generation: generation, transferID: "B")
        XCTAssertFalse(chooser.consume(old, generation: generation, transferID: "B"))
        XCTAssertTrue(chooser.consume(current, generation: generation, transferID: "B"))
        XCTAssertFalse(chooser.consume(current, generation: generation, transferID: "B"))
    }

    func testChooserRejectsChangedTransferAndGenerationBeforeMutation() {
        var chooser = MacFileChooserOwnership()
        let generation = UUID()
        let token = chooser.begin(generation: generation, transferID: "A")
        XCTAssertFalse(chooser.consume(token, generation: generation, transferID: "B"))
        XCTAssertFalse(chooser.consume(token, generation: UUID(), transferID: "A"))
        XCTAssertTrue(chooser.consume(token, generation: generation, transferID: "A"))
        let send = chooser.begin(generation: generation, transferID: nil)
        chooser.invalidate()
        XCTAssertFalse(chooser.consume(send, generation: generation, transferID: nil))
    }

    func testRepeatedCancellationPreservesUnconfirmedSavedOutcome() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("empty")
        try Data().write(to: source)
        let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root.appendingPathComponent("stage"))
        let offer = try await engine.prepareSend(source: source)
        let id = offer.state.transferID!
        let complete = await engine.receive(envelope(.fileAccept, id: id))
        XCTAssertEqual(complete.outgoing.first?.type, .fileComplete)
        let cancelled = await engine.cancel()
        XCTAssertEqual(cancelled.state.phase, .unconfirmed)
        let again = await engine.cancel(reason: "disconnected")
        XCTAssertEqual(again.state.phase, .unconfirmed)
        XCTAssertEqual(again.state.detail, cancelled.state.detail)
    }
    func testDeadlineCrossingDuringExportPreservesExistingDestination() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("snapshot")
        let destination = root.appendingPathComponent("existing")
        try Data("new".utf8).write(to: source)
        try Data("preserve".utf8).write(to: destination)
        let clock = TestFileClock()
        XCTAssertThrowsError(try MacFileTransfer.atomicExport(source, destination, check: {
            clock.advance(100)
            guard clock.read() < 300 else { throw MacFileTransfer.Failure.unavailable }
        }))
        XCTAssertEqual(try Data(contentsOf: destination), Data("preserve".utf8))
    }
    func testSnapshotSurvivesInputMutationAndTerminalFramesDoNotResave() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input")
        try Data("original".utf8).write(to: source)
        let sender = MacFileTransfer(localID: "mac", peerID: "pixel", root: root.appendingPathComponent("send"))
        let receiver = MacFileTransfer(localID: "pixel", peerID: "mac", root: root.appendingPathComponent("receive"))
        _ = await receiver.setReceivingEnabled(true)
        let offer = try await sender.prepareSend(source: source)
        try Data("modified".utf8).write(to: source)
        try FileManager.default.removeItem(at: source)
        let pending = await receiver.receive(offer.outgoing[0])
        let destination = root.appendingPathComponent("chosen")
        try Data("previous".utf8).write(to: destination)
        var queue = (await receiver.accept(transferID: pending.state.transferID!, destination: destination)).outgoing
        var complete: PlinkEnvelope?
        while !queue.isEmpty {
            let message = queue.removeFirst()
            if message.type == .fileComplete { complete = message }
            if message.type == .fileResult { continue }
            let result = message.targetDeviceId == "mac" ? await sender.receive(message) : await receiver.receive(message)
            queue += result.outgoing
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        try Data("user changed saved file".utf8).write(to: destination)
        let duplicate = await receiver.receive(complete!)
        XCTAssertTrue(duplicate.outgoing.isEmpty)
        _ = await sender.cancel(reason: "timeout")
        var lateCancel = complete!; lateCancel.type = .fileCancel
        lateCancel.payload = ["transferId": offer.outgoing[0].payload["transferId"]!, "reason": .string("cancelled")]
        _ = await receiver.receive(lateCancel)
        XCTAssertEqual(try Data(contentsOf: destination), Data("user changed saved file".utf8))
        let final = await sender.snapshot()
        XCTAssertEqual(final.phase, .unconfirmed)
    }

    func testAbsoluteDeadlineCannotBeExtendedBySuccessfulProgress() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestFileClock()
        let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root.appendingPathComponent("stage"), now: { clock.read() })
        _ = await engine.setReceivingEnabled(true)
        var offer = offerEnvelope(); offer.payload["sizeBytes"] = .int(16_777_216)
        let pending = await engine.receive(offer)
        let id = pending.state.transferID!
        _ = await engine.accept(transferID: id, destination: root.appendingPathComponent("chosen"))
        for index in 0..<10 {
            clock.advance(29)
            let progress = await engine.receive(envelope(.fileChunk, id: id,
                extra: ["index": .int(index), "data": .string(Data(repeating: 1, count: 32_768).base64EncodedString())]))
            XCTAssertEqual(progress.outgoing.first?.type, .fileProgress)
        }
        clock.advance(10)
        let expired = await engine.tick()
        XCTAssertNil(expired.state.transferID)
        XCTAssertEqual(expired.outgoing.first?.payload["reason"], .string("timeout"))
    }

    func testBusyAndStaleConsentCannotTakeOverExistingTransfer() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input"); try Data("x".utf8).write(to: source)
        let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root.appendingPathComponent("stage"))
        _ = await engine.setReceivingEnabled(true)
        let a = await engine.receive(offerEnvelope())
        do { _ = try await engine.prepareSend(source: source); XCTFail("Busy slot accepted sender") }
        catch { XCTAssertEqual(error as? MacFileTransfer.Failure, .busy) }
        _ = await engine.cancel()
        let b = await engine.receive(offerEnvelope())
        let stale = await engine.accept(transferID: a.state.transferID!, destination: root.appendingPathComponent("old-target"))
        XCTAssertEqual(stale.state.transferID, b.state.transferID)
        XCTAssertTrue(stale.outgoing.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("old-target").path))
        _ = await engine.cancel()
    }

    func testNoncanonicalBase64IsRejectedBeforeWrite() async throws {
        for data in ["Zh==", "Zg", "Zg==\n", "_w=="] {
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root.appendingPathComponent("stage"))
            _ = await engine.setReceivingEnabled(true)
            let pending = await engine.receive(offerEnvelope())
            let id = pending.state.transferID!
            _ = await engine.accept(transferID: id, destination: root.appendingPathComponent("chosen"))
            let failed = await engine.receive(envelope(.fileChunk, id: id, extra: ["index": .int(0), "data": .string(data)]))
            XCTAssertEqual(failed.state.phase, .failed)
            XCTAssertEqual(failed.state.completedBytes, 0)
        }
    }
    func testSenderNeverSendsBeforeAcceptOrTreatsTransportAsSaved() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input")
        try Data("x".utf8).write(to: source)
        let sender = MacFileTransfer(localID: "mac", peerID: "pixel", root: root.appendingPathComponent("stage"))
        let offer = try await sender.prepareSend(source: source)
        let id = offer.state.transferID!
        let tick = await sender.tick()
        XCTAssertTrue(tick.outgoing.isEmpty)
        let chunk = await sender.receive(envelope(.fileAccept, id: id))
        XCTAssertEqual(chunk.outgoing.first?.type, .fileChunk)
        let complete = await sender.receive(envelope(.fileProgress, id: id, extra: ["nextIndex": .int(1)]))
        XCTAssertEqual(complete.outgoing.first?.type, .fileComplete)
        XCTAssertNotEqual(complete.state.phase, .saved)
        let lost = await sender.transportFailed(transferID: id)
        XCTAssertEqual(lost.state.phase, .unconfirmed)
        let late = await sender.receive(envelope(.fileResult, id: id, extra: ["status": .string("saved")]))
        XCTAssertEqual(late.state.phase, .unconfirmed)
    }

    func testMalformedActiveChunkStopsAndCleans() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root.appendingPathComponent("stage"))
        _ = await engine.setReceivingEnabled(true)
        let pending = await engine.receive(offerEnvelope())
        let id = pending.state.transferID!
        _ = await engine.accept(transferID: id, destination: root.appendingPathComponent("chosen"))
        let invalid = await engine.receive(envelope(.fileChunk, id: id, extra: ["index": .bool(true), "data": .string("eA==")]))
        XCTAssertEqual(invalid.state.phase, .failed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("stage").path).isEmpty)
    }
    func testBidirectionalBoundaryFilesSaveIdenticalBytesOnlyAfterConsent() async throws {
        for size in [0, 1, 32_768, 32_769, 16_777_216] {
            for reverse in [false, true] {
                let root = temporaryRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let source = root.appendingPathComponent("source.bin")
                let destination = root.appendingPathComponent("chosen.bin")
                let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
                try bytes.write(to: source)
                let senderID = reverse ? "pixel" : "mac"
                let peerID = reverse ? "mac" : "pixel"
                let sender = MacFileTransfer(localID: senderID, peerID: peerID, root: root.appendingPathComponent("sender"))
                let receiver = MacFileTransfer(localID: peerID, peerID: senderID, root: root.appendingPathComponent("receiver"))
                _ = await receiver.setReceivingEnabled(true)
                let offer = try await sender.prepareSend(source: source)
                XCTAssertEqual(offer.outgoing.map(\.type), [.fileOffer])
                let waiting = await receiver.receive(offer.outgoing[0])
                XCTAssertTrue(waiting.outgoing.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                var queue = (await receiver.accept(transferID: waiting.state.transferID!, destination: destination)).outgoing
                var count = 0
                while !queue.isEmpty {
                    let message = queue.removeFirst()
                    let update = message.targetDeviceId == senderID
                        ? await sender.receive(message) : await receiver.receive(message)
                    queue.append(contentsOf: update.outgoing)
                    count += 1
                    XCTAssertLessThan(count, 1_100)
                }
                let final = await sender.snapshot()
                XCTAssertEqual(final.phase, .saved)
                XCTAssertEqual(try Data(contentsOf: destination), bytes)
                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: destination)), SHA256.hash(data: bytes))
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sender").path).isEmpty)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("receiver").path).isEmpty)
            }
        }
    }

    func testOversizeNeverOffersAndCleansSnapshot() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large")
        try Data(repeating: 0, count: 16_777_217).write(to: source)
        let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root.appendingPathComponent("stage"))
        do { _ = try await engine.prepareSend(source: source); XCTFail("Oversize source offered") }
        catch { XCTAssertEqual(error as? MacFileTransfer.Failure, .tooLarge) }
        let state = await engine.snapshot()
        XCTAssertNil(state.transferID)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("stage").path).isEmpty)
    }

    func testDisabledBusyForeignAndUnacceptedMessagesCannotWrite() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root)
        let offer = offerEnvelope()
        let disabled = await engine.receive(offer)
        XCTAssertEqual(disabled.outgoing.first?.payload["code"], .string("receive_unavailable"))
        _ = await engine.setReceivingEnabled(true)
        let pending = await engine.receive(offer)
        var other = offer; other.payload["transferId"] = .string(UUID().uuidString.lowercased())
        let busy = await engine.receive(other)
        XCTAssertEqual(busy.outgoing.first?.payload["code"], .string("busy"))
        var foreign = offer; foreign.sourceDeviceId = "other-phone"
        _ = await engine.receive(foreign)
        let afterForeign = await engine.snapshot()
        XCTAssertEqual(afterForeign.transferID, pending.state.transferID)
        let chunk = envelope(.fileChunk, id: pending.state.transferID!, extra: ["index": .int(0), "data": .string("eA==")])
        let rejected = await engine.receive(chunk)
        XCTAssertEqual(rejected.state.phase, .failed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testWrongIndexLengthAndDigestNeverSave() async throws {
        for mode in ["index", "length", "digest", "wrong-id"] {
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("existing")
            try Data("preserve".utf8).write(to: destination)
            let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root.appendingPathComponent("stage"))
            _ = await engine.setReceivingEnabled(true)
            let pending = await engine.receive(offerEnvelope())
            let id = pending.state.transferID!
            _ = await engine.accept(transferID: id, destination: destination)
            let chunk = envelope(.fileChunk, id: mode == "wrong-id" ? UUID().uuidString.lowercased() : id,
                extra: ["index": .int(mode == "index" ? 1 : 0), "data": .string(mode == "length" ? "eHg=" : "eA==")])
            _ = await engine.receive(chunk)
            _ = await engine.receive(envelope(.fileComplete, id: id))
            let final = await engine.snapshot()
            XCTAssertNotEqual(final.phase, .saved)
            XCTAssertEqual(try Data(contentsOf: destination), Data("preserve".utf8))
        }
    }

    func testCancellationFeatureOffAndSessionResetRevokeConsentAndClean() async throws {
        for mode in ["cancel", "off", "reset"] {
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root)
            _ = await engine.setReceivingEnabled(true)
            let pending = await engine.receive(offerEnvelope())
            let id = pending.state.transferID!
            if mode == "off" { _ = await engine.setReceivingEnabled(false) }
            else { _ = await engine.cancel(reason: mode == "reset" ? "disconnected" : "cancelled") }
            let stale = await engine.accept(transferID: id, destination: root.appendingPathComponent("output"))
            XCTAssertTrue(stale.outgoing.isEmpty)
            XCTAssertNil(stale.state.transferID)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    func testMonotonicOfferInactivityAndAbsoluteDeadlines() async throws {
        for mode in ["offer", "idle", "absolute"] {
            let clock = TestFileClock()
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root, now: { clock.read() })
            _ = await engine.setReceivingEnabled(true)
            let pending = await engine.receive(offerEnvelope())
            if mode != "offer" { _ = await engine.accept(transferID: pending.state.transferID!, destination: root.appendingPathComponent("out")) }
            clock.advance(mode == "offer" ? 61 : mode == "idle" ? 31 : 301)
            let expired = await engine.tick()
            XCTAssertNil(expired.state.transferID)
            XCTAssertEqual(expired.outgoing.first?.payload["reason"], .string("timeout"))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    func testExportFailureNeverReportsSavedAndPathTraversalRejected() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacFileTransfer(localID: "mac", peerID: "pixel", root: root,
            export: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        _ = await engine.setReceivingEnabled(true)
        var bad = offerEnvelope(); bad.payload["name"] = .string("../outside")
        let invalid = await engine.receive(bad)
        XCTAssertNil(invalid.state.transferID)
        var valid = offerEnvelope(); valid.payload["sizeBytes"] = .int(0)
        valid.payload["sha256"] = .string(SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())
        let pending = await engine.receive(valid)
        let id = pending.state.transferID!
        _ = await engine.accept(transferID: id, destination: root.appendingPathComponent("chosen"))
        let failed = await engine.receive(envelope(.fileComplete, id: id))
        XCTAssertEqual(failed.outgoing.first?.payload["status"], .string("error"))
        XCTAssertEqual(failed.outgoing.first?.payload["code"], .string("storage"))
        XCTAssertNotEqual(failed.state.phase, .saved)
    }

    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plink-file-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func offerEnvelope() -> PlinkEnvelope {
        envelope(.fileOffer, id: UUID().uuidString.lowercased(), extra: ["name": .string("sample.bin"), "mimeType": .string("application/octet-stream"),
            "sizeBytes": .int(1), "sha256": .string(String(repeating: "0", count: 64)), "chunkBytes": .int(32_768)])
    }
    private func envelope(_ type: EventType, id: String, extra: [String: PayloadValue] = [:]) -> PlinkEnvelope {
        PlinkEnvelope(id: UUID().uuidString.lowercased(), type: type, sentAt: .now, sourceDeviceId: "pixel", targetDeviceId: "mac",
            payload: extra.merging(["transferId": .string(id)]) { _, new in new })
    }
}

private final class TestFileClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

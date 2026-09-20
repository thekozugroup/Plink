import Foundation
import CryptoKit

/// One-use ownership of an asynchronous native chooser completion. Check before
/// any callback mutation, including cancellation, so an old panel cannot affect
/// a replacement offer in the same authenticated session.
public struct MacFileChooserOwnership: Sendable {
    private var current: (token: UUID, generation: UUID, transferID: String?)?
    public init() {}
    public mutating func begin(generation: UUID, transferID: String?) -> UUID {
        let token = UUID()
        current = (token, generation, transferID)
        return token
    }
    public mutating func invalidate() { current = nil }
    public mutating func consume(_ token: UUID, generation: UUID, transferID: String?) -> Bool {
        guard let current, current.token == token, current.generation == generation,
              current.transferID == transferID else { return false }
        self.current = nil
        return true
    }
}

/// One selected, authenticated peer/session owns one instance. File operations run
/// on this actor, never on the UI actor. Protocol validation remains parent-owned.
public actor MacFileTransfer {
    public enum Failure: Error, Equatable { case busy, tooLarge, invalid, unavailable }
    public enum Phase: String, Sendable { case idle, preparing, offered, pendingConsent, sending, receiving, verifying, saved, cancelled, failed, unconfirmed }
    public struct State: Sendable {
        public var transferID: String?
        public var name = ""
        public var size = 0
        public var completedBytes = 0
        public var phase: Phase = .idle
        public var detail = "No file transfer"
        public var canAccept: Bool { phase == .pendingConsent && transferID != nil }
        public init(transferID: String? = nil, name: String = "", size: Int = 0,
                    completedBytes: Int = 0, phase: Phase = .idle, detail: String = "No file transfer") {
            self.transferID = transferID; self.name = name; self.size = size
            self.completedBytes = completedBytes; self.phase = phase; self.detail = detail
        }
    }
    public struct Update: Sendable {
        public let state: State
        public let outgoing: [PlinkEnvelope]
    }
    private struct Transfer {
        let id: String
        let sending: Bool
        let size: Int
        let digest: String
        let stage: URL
        let started: TimeInterval
        var lastActivity: TimeInterval
        var destination: URL?
        var handle: FileHandle?
        var hash = SHA256()
        var index = 0
        var bytes = 0
        var accepted = false
        var awaitingProgress = false
        var awaitingResult = false
    }
    private let localID: String
    private let peerID: String
    private let root: URL
    private let now: @Sendable () -> TimeInterval
    private let export: (@Sendable (URL, URL) throws -> Void)?
    private var receivingEnabled = false
    private var transfer: Transfer?
    private var state = State()

    public init(localID: String, peerID: String, root: URL,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                export: (@Sendable (URL, URL) throws -> Void)? = nil) {
        self.localID = localID; self.peerID = peerID; self.root = root
        self.now = now; self.export = export
    }

    public func snapshot() -> State { state }
    public func setReceivingEnabled(_ enabled: Bool) -> Update {
        receivingEnabled = enabled
        return enabled ? update() : cancel(reason: "cancelled")
    }

    public func prepareSend(source: URL) throws -> Update {
        guard transfer == nil else { throw Failure.busy }
        try prepareRoot()
        let id = UUID().uuidString.lowercased()
        let stage = root.appendingPathComponent(id)
        let started = now()
        state = State(transferID: id, name: source.lastPathComponent, phase: .preparing, detail: "Preparing file…")
        do {
            let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw Failure.invalid }
            guard FileManager.default.createFile(atPath: stage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: stage)
            defer { try? output.close() }
            var size = 0
            var hash = SHA256()
            while let chunk = try input.read(upToCount: FileTransferPayloadPolicy.chunkBytes), !chunk.isEmpty {
                try Task.checkCancellation()
                guard now() - started < 300 else { throw Failure.unavailable }
                size += chunk.count
                guard size <= FileTransferPayloadPolicy.maxFileBytes else { throw Failure.tooLarge }
                try output.write(contentsOf: chunk)
                hash.update(data: chunk)
            }
            try output.synchronize()
            try output.close()
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let offer = envelope(.fileOffer, id: id, ["name": .string(source.lastPathComponent), "mimeType": .string("application/octet-stream"),
                "sizeBytes": .int(size), "sha256": .string(digest), "chunkBytes": .int(FileTransferPayloadPolicy.chunkBytes)])
            try FileTransferPayloadPolicy.validate(offer)
            try Task.checkCancellation()
            transfer = Transfer(id: id, sending: true, size: size, digest: digest, stage: stage, started: started, lastActivity: now())
            state = State(transferID: id, name: source.lastPathComponent, size: size, phase: .offered, detail: "Waiting for phone acceptance…")
            return update([offer])
        } catch {
            try? FileManager.default.removeItem(at: stage)
            state.transferID = nil; state.phase = .failed; state.detail = "Could not prepare file. Nothing was offered."
            throw error
        }
    }

    public func accept(transferID: String, destination: URL) -> Update {
        guard receivingEnabled, var active = transfer, active.id == transferID, !active.sending,
              !active.accepted, state.phase == .pendingConsent else { return update() }
        if expired(active) { return cancel(reason: "timeout") }
        do {
            try Task.checkCancellation()
            try prepareRoot()
            guard FileManager.default.createFile(atPath: active.stage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            active.handle = try FileHandle(forWritingTo: active.stage)
            active.destination = destination
            active.accepted = true; active.lastActivity = now()
            transfer = active
            state.phase = .receiving; state.detail = "Receiving file…"
            return update([envelope(.fileAccept, id: active.id)])
        } catch { return fail(code: "storage") }
    }

    public func receive(_ message: PlinkEnvelope) -> Update {
        guard message.sourceDeviceId == peerID, message.targetDeviceId == localID else { return update() }
        guard message.type.rawValue.hasPrefix("file.") else { return update() }
        do { try FileTransferPayloadPolicy.validate(message) }
        catch {
            if message.payload["transferId"]?.stringValue == transfer?.id, transfer != nil { return fail(code: "invalid") }
            return update()
        }
        guard let id = message.payload["transferId"]?.stringValue else { return update() }
        if let active = transfer, expired(active) { return cancel(reason: "timeout") }
        if message.type == .fileOffer {
            guard receivingEnabled else { return update([result(id, code: "receive_unavailable")]) }
            guard transfer == nil else { return update([result(id, code: "busy")]) }
            guard let size = integer(message.payload["sizeBytes"]),
                  let name = message.payload["name"]?.stringValue,
                  let digest = message.payload["sha256"]?.stringValue else { return update([result(id, code: "invalid")]) }
            transfer = Transfer(id: id, sending: false, size: size, digest: digest,
                stage: root.appendingPathComponent(id), started: now(), lastActivity: now())
            state = State(transferID: id, name: name, size: size, phase: .pendingConsent, detail: "Phone offered a file. Accept to choose where to save it.")
            return update()
        }
        guard var active = transfer, active.id == id else { return update() }
        do {
            try Task.checkCancellation()
            switch message.type {
            case .fileCancel:
                return finish(.cancelled, "Transfer cancelled by phone.")
            case .fileResult:
                guard active.sending else { return fail(code: "invalid") }
                if message.payload["status"]?.stringValue == "saved" {
                    guard active.awaitingResult else { return fail(code: "invalid") }
                    return finish(.saved, "Phone confirmed the file was saved.")
                }
                return finish(.failed, "Phone could not receive the file (\(message.payload["code"]?.stringValue ?? "invalid")).")
            case .fileAccept:
                guard active.sending, !active.accepted else { return fail(code: "invalid") }
                active.accepted = true; active.lastActivity = now()
                active.handle = try FileHandle(forReadingFrom: active.stage)
                transfer = active
                return try nextChunk()
            case .fileProgress:
                guard active.sending, active.accepted, active.awaitingProgress,
                      let next = integer(message.payload["nextIndex"]), next == active.index + 1 else { return fail(code: "invalid") }
                active.index = next; active.awaitingProgress = false; active.lastActivity = now()
                state.completedBytes = active.bytes
                transfer = active
                return try nextChunk()
            case .fileChunk:
                guard !active.sending, active.accepted, let handle = active.handle,
                      let index = integer(message.payload["index"]), index == active.index,
                      let encoded = message.payload["data"]?.stringValue, let bytes = Data(base64Encoded: encoded),
                      bytes.count == min(FileTransferPayloadPolicy.chunkBytes, active.size - active.bytes),
                      !bytes.isEmpty else { return fail(code: "invalid") }
                try handle.write(contentsOf: bytes)
                active.hash.update(data: bytes); active.bytes += bytes.count; active.index += 1; active.lastActivity = now()
                transfer = active; state.completedBytes = active.bytes
                return update([envelope(.fileProgress, id: id, ["nextIndex": .int(active.index)])])
            case .fileComplete:
                guard !active.sending, active.accepted, active.bytes == active.size,
                      let destination = active.destination, let handle = active.handle,
                      active.hash.finalize().map({ String(format: "%02x", $0) }).joined() == active.digest else { return fail(code: "invalid") }
                state.phase = .verifying; state.detail = "Verifying and saving file…"
                try handle.synchronize(); try handle.close()
                active.handle = nil; transfer = active
                try Task.checkCancellation()
                guard !expired(active) else { return cancel(reason: "timeout") }
                if let export {
                    // Injected exporters must cooperate with cancellation/deadlines.
                    // A blocked external provider cannot be preempted safely.
                    try export(active.stage, destination)
                } else {
                    let deadline = min(active.started + 300, now() + 30)
                    let clock = now
                    try Self.atomicExport(active.stage, destination) {
                        try Task.checkCancellation()
                        guard clock() < deadline else { throw Failure.unavailable }
                    }
                }
                return finish(.saved, "File saved to your selected destination.", [envelope(.fileResult, id: id, ["status": .string("saved")])])
            default: return fail(code: "invalid")
            }
        } catch is CancellationError { return cancel(reason: "cancelled") }
        catch Failure.unavailable { return cancel(reason: "timeout") }
        catch { return fail(code: "storage") }
    }

    public func tick() -> Update {
        if let active = transfer, expired(active) { return cancel(reason: "timeout") }
        return update()
    }
    public func cancel(reason: String = "cancelled") -> Update {
        guard let active = transfer else { return update() }
        let unknown = active.sending && active.awaitingResult
        return finish(unknown ? .unconfirmed : .cancelled,
            unknown ? "Save outcome is unconfirmed. Check the phone before retrying." : "Transfer ended (\(reason)).",
            [envelope(.fileCancel, id: active.id, ["reason": .string(reason)])])
    }
    public func transportFailed(transferID: String) -> Update {
        guard let active = transfer, active.id == transferID else { return update() }
        return finish(active.sending && active.awaitingResult ? .unconfirmed : .failed,
            "Connection failed. Saving was not confirmed; check the other device before retrying.")
    }

    private func nextChunk() throws -> Update {
        guard var active = transfer, active.sending, active.accepted, !active.awaitingProgress, !active.awaitingResult else { throw Failure.invalid }
        if active.bytes == active.size {
            active.awaitingResult = true; active.lastActivity = now(); transfer = active
            state.detail = "Bytes transferred; waiting for phone save confirmation…"
            return update([envelope(.fileComplete, id: active.id)])
        }
        guard let bytes = try active.handle?.read(upToCount: min(FileTransferPayloadPolicy.chunkBytes, active.size - active.bytes)),
              bytes.count == min(FileTransferPayloadPolicy.chunkBytes, active.size - active.bytes) else { throw Failure.invalid }
        active.bytes += bytes.count; active.awaitingProgress = true; active.lastActivity = now(); transfer = active
        state.phase = .sending; state.detail = "Sending file…"
        return update([envelope(.fileChunk, id: active.id, ["index": .int(active.index), "data": .string(bytes.base64EncodedString())])])
    }
    private func expired(_ active: Transfer) -> Bool {
        now() - active.started >= 300 || now() - active.lastActivity >= (active.accepted ? 30 : 60)
    }
    private func fail(code: String) -> Update {
        guard let active = transfer else { return update() }
        return finish(.failed, "File transfer failed (\(code)).", [result(active.id, code: code)])
    }
    private func finish(_ phase: Phase, _ detail: String, _ outgoing: [PlinkEnvelope] = []) -> Update {
        if let active = transfer {
            try? active.handle?.close()
            try? FileManager.default.removeItem(at: active.stage)
        }
        transfer = nil; state.transferID = nil; state.phase = phase; state.detail = detail
        return update(outgoing)
    }
    private func result(_ id: String, code: String) -> PlinkEnvelope {
        envelope(.fileResult, id: id, ["status": .string("error"), "code": .string(code)])
    }
    private func update(_ outgoing: [PlinkEnvelope] = []) -> Update { Update(state: state, outgoing: outgoing) }
    private func envelope(_ type: EventType, id: String, _ payload: [String: PayloadValue] = [:]) -> PlinkEnvelope {
        PlinkEnvelope(id: UUID().uuidString.lowercased(), type: type, sentAt: .now, sourceDeviceId: localID, targetDeviceId: peerID,
            payload: payload.merging(["transferId": .string(id)]) { _, value in value })
    }
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    // Shared validation has already bounded these values and rejected fractions.
    private func integer(_ value: PayloadValue?) -> Int? {
        switch value { case .int(let number): return number
        case .double(let number): return Int(exactly: number)
        default: return nil }
    }

    /// Destination is supplied only by the local save chooser, never the offer.
    public static func atomicExport(_ source: URL, _ destination: URL) throws {
        try atomicExport(source, destination, check: { try Task.checkCancellation() })
    }

    static func atomicExport(_ source: URL, _ destination: URL, check: @Sendable () throws -> Void) throws {
        try check()
        let manager = FileManager.default
        let replacement = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: replacement) }
        let temporary = replacement.appendingPathComponent(UUID().uuidString)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        while let bytes = try input.read(upToCount: FileTransferPayloadPolicy.chunkBytes), !bytes.isEmpty {
            try check()
            try output.write(contentsOf: bytes)
        }
        try output.synchronize(); try output.close()
        try check()
        var coordinationError: NSError?
        var exportError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            do {
                try check()
                if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temporary) }
                else { try manager.moveItem(at: temporary, to: url) }
            } catch { exportError = error }
        }
        if let coordinationError { throw coordinationError }
        if let exportError { throw exportError }
    }
}

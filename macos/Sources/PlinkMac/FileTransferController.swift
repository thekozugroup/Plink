import AppKit
import Combine
import Darwin
import PlinkCore
import SwiftUI

/// Native consent and display only. The engine performs hashing and file IO off
/// MainActor; one bounded operation queue prevents inbound traffic spawning tasks.
@MainActor
final class FileTransferController: ObservableObject {
    @Published private(set) var state = MacFileTransfer.State()
    @Published private(set) var connected = false
    @Published private(set) var choosing = false
    @Published var enabled = UserDefaults.standard.bool(forKey: "plink.receiveFiles") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "plink.receiveFiles")
            if !enabled { cancel(reason: "cancelled") }
            enqueue(.permission(enabled))
        }
    }
    private enum Operation {
        case incoming(PlinkEnvelope), prepare(URL), accept(String, URL), tick, permission(Bool)
    }
    private var engine: MacFileTransfer?
    private var transport: (any PlinkTransport)?
    private var localID = ""
    private var peerID = ""
    private var generation = UUID()
    private var queue: [Operation] = []
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var destinationScope: URL?
    private var panel: NSSavePanel?
    private var chooserOwnership = MacFileChooserOwnership()
    private let staging = FileTransferStagingHome()

    var canSend: Bool { connected && enabled && !choosing && state.transferID == nil && work == nil }

    func bind(localID: String, peerID: String, transport: any PlinkTransport) {
        reset()
        guard let root = staging.root else { state.detail = "Private file staging is unavailable."; return }
        self.localID = localID; self.peerID = peerID; self.transport = transport
        engine = MacFileTransfer(localID: localID, peerID: peerID, root: root.appendingPathComponent(generation.uuidString))
        connected = true
        enqueue(.permission(enabled))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if self.work == nil && self.state.transferID != nil { self.enqueue(.tick) }
            }
        }
    }

    func reset() {
        timer?.cancel(); timer = nil
        terminateCurrent(reason: "disconnected")
        engine = nil; transport = nil; connected = false
        state = MacFileTransfer.State()
    }

    func cancel(reason: String = "cancelled") {
        terminateCurrent(reason: reason)
    }

    private func terminateCurrent(reason: String) {
        generation = UUID()
        dismissChooser()
        queue.removeAll()
        let previous = work; previous?.cancel(); work = nil
        let oldEngine = engine, oldTransport = transport
        let scope = destinationScope; destinationScope = nil
        let token = generation
        // Cleanup is sequenced after any in-flight IO. Never release the security
        // scope or remove a staging file while the old operation still uses it.
        work = Task { [weak self] in
            await previous?.value
            if let oldEngine {
                let update = await oldEngine.cancel(reason: reason)
                if let self, self.generation == token, self.engine === oldEngine {
                    self.apply(update.state)
                }
                for envelope in update.outgoing { try? await oldTransport?.send(envelope) }
            }
            scope?.stopAccessingSecurityScopedResource()
            guard let self, self.generation == token else { return }
            self.work = nil
            self.drain()
        }
    }

    func chooseFile() {
        guard canSend else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false; picker.canChooseFiles = true
        picker.allowsMultipleSelection = false; picker.resolvesAliases = false
        picker.treatsFilePackagesAsDirectories = true
        picker.prompt = "Send File"
        let token = generation
        let chooser = chooserOwnership.begin(generation: token, transferID: nil)
        choosing = true; panel = picker
        picker.begin { [weak self] response in
            guard let self, self.generation == token,
                  self.chooserOwnership.consume(chooser, generation: token, transferID: self.state.transferID) else { return }
            self.panel = nil; self.choosing = false
            guard response == .OK, self.enabled, let source = picker.url else { return }
            self.enqueue(.prepare(source))
        }
    }

    func acceptOffer() {
        guard connected, enabled, state.canAccept, !choosing, work == nil, let id = state.transferID else { return }
        let picker = NSSavePanel()
        picker.nameFieldStringValue = state.name
        picker.canCreateDirectories = true; picker.prompt = "Receive File"
        let token = generation
        let chooser = chooserOwnership.begin(generation: token, transferID: id)
        choosing = true; panel = picker
        picker.begin { [weak self] response in
            guard let self, self.generation == token,
                  self.chooserOwnership.consume(chooser, generation: token, transferID: self.state.transferID) else { return }
            self.panel = nil; self.choosing = false
            guard response == .OK, let destination = picker.url else { self.cancel(); return }
            guard self.enabled, self.state.transferID == id, self.state.canAccept else { return }
            if destination.startAccessingSecurityScopedResource() { self.destinationScope = destination }
            self.enqueue(.accept(id, destination))
        }
    }

    func receive(_ envelope: PlinkEnvelope) {
        guard connected, envelope.sourceDeviceId == peerID, envelope.targetDeviceId == localID else { return }
        enqueue(.incoming(envelope))
    }

    private func enqueue(_ operation: Operation) {
        guard engine != nil else { return }
        // Normal stop-and-wait needs at most one queued peer message. A small
        // bound also accommodates permission/timer events without unbounded work.
        guard queue.count < 4 else { cancel(reason: "invalid"); return }
        queue.append(operation)
        drain()
    }

    private func drain() {
        guard work == nil, !queue.isEmpty, let engine, let transport else { return }
        let token = generation
        work = Task { [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty, self.generation == token, !Task.isCancelled {
                let operation = self.queue.removeFirst()
                let update: MacFileTransfer.Update
                switch operation {
                case .incoming(let envelope):
                    if self.choosing, self.state.transferID == nil, envelope.type == .fileOffer {
                        // Outgoing chooser already reserved this peer's single slot.
                        if let id = envelope.payload["transferId"]?.stringValue,
                           (try? FileTransferPayloadPolicy.validate(envelope)) != nil {
                            let busy = PlinkEnvelope(id: UUID().uuidString.lowercased(), type: .fileResult, sentAt: .now,
                                sourceDeviceId: self.localID, targetDeviceId: self.peerID,
                                payload: ["transferId": .string(id), "status": .string("error"), "code": .string("busy")])
                            try? await transport.send(busy)
                        }
                        continue
                    }
                    update = await engine.receive(envelope)
                case .prepare(let source):
                    self.state = MacFileTransfer.State(name: source.lastPathComponent, phase: .preparing, detail: "Preparing file…")
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    do { update = try await engine.prepareSend(source: source) }
                    catch {
                        if self.generation == token { self.state = await engine.snapshot() }
                        continue
                    }
                case .accept(let id, let destination): update = await engine.accept(transferID: id, destination: destination)
                case .tick: update = await engine.tick()
                case .permission(let enabled): update = await engine.setReceivingEnabled(enabled)
                }
                guard self.generation == token, !Task.isCancelled else { break }
                self.apply(update.state)
                for message in update.outgoing {
                    do { try await transport.send(message) }
                    catch {
                        guard self.generation == token else { break }
                        let failed = await engine.transportFailed(transferID: message.payload["transferId"]?.stringValue ?? "")
                        self.apply(failed.state)
                        self.queue.removeAll()
                        break
                    }
                }
            }
            guard self.generation == token else { return }
            self.work = nil
            self.drain()
        }
    }

    private func apply(_ newState: MacFileTransfer.State) {
        state = newState
        if state.transferID == nil {
            dismissChooser()
            destinationScope?.stopAccessingSecurityScopedResource(); destinationScope = nil
        }
    }

    private func dismissChooser() {
        chooserOwnership.invalidate()
        let oldPanel = panel
        panel = nil; choosing = false
        oldPanel?.cancel(nil)
    }
}

/// Each live process locks its own staging directory. Startup removes only
/// abandoned Plink directories with our lock marker; other live instances survive.
private final class FileTransferStagingHome {
    let root: URL?
    private let descriptor: Int32
    init() {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("PlinkFileTransfer", isDirectory: true)
        var fd: Int32 = -1
        var created: URL?
        do {
            try manager.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for candidate in (try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
                guard UUID(uuidString: candidate.lastPathComponent) != nil,
                      (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
                let lockURL = candidate.appendingPathComponent(".owner.lock")
                let old = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW)
                if old >= 0 {
                    if flock(old, LOCK_EX | LOCK_NB) == 0 { try? manager.removeItem(at: candidate) }
                    Darwin.close(old)
                }
            }
            let path = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            fd = Darwin.open(path.appendingPathComponent(".owner.lock").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteUnknown) }
            created = path
        } catch { if fd >= 0 { Darwin.close(fd); fd = -1 } }
        descriptor = fd; root = created
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}

struct FileTransferPanel: View {
    @ObservedObject var controller: FileTransferController
    var body: some View {
        GroupBox("Files") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable file transfers", isOn: $controller.enabled).disabled(!controller.connected)
                Text("Choose each file to send and where to save incoming files. Maximum 16 MB.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Send File…") { controller.chooseFile() }.disabled(!controller.canSend)
                Text(controller.state.detail).textSelection(.enabled)
                if controller.state.transferID != nil {
                    Text(controller.state.name).font(.headline)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(controller.state.size), countStyle: .file))
                    if controller.state.canAccept {
                        HStack {
                            Button("Accept…") { controller.acceptOffer() }.disabled(controller.choosing)
                            Button("Reject") { controller.cancel() }
                        }
                    } else {
                        ProgressView(value: Double(controller.state.completedBytes), total: Double(max(1, controller.state.size)))
                        Button("Cancel") { controller.cancel() }
                    }
                } else if controller.state.phase == .preparing {
                    ProgressView()
                    Button("Cancel") { controller.cancel() }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

struct FileTransferMenu: View {
    @ObservedObject var controller: FileTransferController
    let openDashboard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Send File…") { controller.chooseFile() }.disabled(!controller.canSend)
            if controller.state.transferID != nil {
                Text(controller.state.detail).font(.caption)
                Button("Show File Transfer") { openDashboard() }
            }
        }
    }
}

import AppKit
import Combine
import PlinkCore

/// Owns the foreground preview. The protocol session owns timing and correlation;
/// this owner clears pixels immediately and keeps decode and transport work bounded.
@MainActor
final class ScreenPreviewController: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var snapshot: ScreenPreviewSnapshot?
    @Published private(set) var canStart = false
    @Published private(set) var statusText = "Pair your phone to preview its screen."
    nonisolated let admissionGeneration = ScreenPreviewGeneration()

    private var session: ScreenPreviewSession?
    private var sender: SerializedPlinkSender?
    private var connectionGeneration: UUID?
    private var epoch = UUID()
    private var visible = false
    private var enabled = true
    private var isShutdown = false
    private let decoder = ScreenFrameDecoder()
    private var watchdog: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var decodeID: UUID?
    private var sends: [UUID: Task<Void, Never>] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var cleanupID: UUID?
    private let isAppActive: () -> Bool

    init(isAppActive: @escaping () -> Bool = { NSApp.isActive }) {
        self.isAppActive = isAppActive
    }

    func bind(localID: String, peerID: String, generation: UUID, sender: SerializedPlinkSender) {
        guard !isShutdown else { return }
        unbind()
        session = ScreenPreviewSession(binding: .init(localDeviceID: localID, peerDeviceID: peerID))
        self.sender = sender
        connectionGeneration = generation
        publish()
    }

    func unbind() {
        stop(reason: .disconnected)
        epoch = UUID()
        session = nil
        sender = nil
        connectionGeneration = nil
        publish()
    }

    func setVisible(_ value: Bool) {
        visible = value && !isShutdown
        if !value { stop(reason: .hidden) }
        publish()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { stop(reason: .disabled) }
        publish()
    }

    func start() {
        guard canStart, !isShutdown, isAppActive() else { return }
        epoch = UUID()
        admissionGeneration.set(epoch)
        guard let update = session?.start() else { return }
        apply(update)
    }

    func stop(reason: ScreenPreviewStopReason) {
        guard let update = session?.stop(reason: reason) else {
            image = nil
            publish()
            return
        }
        apply(update)
    }

    func receive(_ envelope: PlinkEnvelope, admission: ScreenPreviewIngressToken, previewGeneration: UUID) {
        guard !isShutdown, previewGeneration == epoch,
              admission.connectionGeneration == connectionGeneration, enabled, visible,
              isAppActive(), session != nil else { admission.release(); return }
        do {
            let update = try session!.receive(envelope)
            if let frame = update.frameEnvelope, let ticket = update.frameTicket {
                guard decodeTask == nil else {
                    admission.release()
                    stop(reason: .protocolError)
                    return
                }
                decode(frame, ticket: ticket, admission: admission)
            } else { admission.release() }
            apply(update)
        } catch {
            admission.release()
            stop(reason: .protocolError)
        }
    }

    func receive(_ rejection: AuthenticatedScreenProtocolRejection, admission: ScreenPreviewIngressToken, previewGeneration: UUID) {
        defer { admission.release() }
        guard !isShutdown, previewGeneration == epoch,
              admission.connectionGeneration == connectionGeneration, enabled, visible,
              isAppActive(), let update = session?.receiveAuthenticatedRejection(rejection) else { return }
        apply(update)
    }

    func beginShutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        visible = false
        stop(reason: .disconnected)
    }

    func shutdown() async {
        beginShutdown()
        await decodeTask?.value
        await cleanupTask?.value
    }

    private func decode(_ envelope: PlinkEnvelope, ticket: ScreenFrameTicket, admission: ScreenPreviewIngressToken) {
        let id = UUID()
        let currentEpoch = epoch
        let decoder = decoder
        decodeID = id
        decodeTask = Task { [weak self] in
            defer {
                admission.release()
                if let self, self.decodeID == id {
                    self.decodeID = nil
                    self.decodeTask = nil
                    self.publish()
                }
            }
            do {
                try Task.checkCancellation()
                let decoded = try await decoder.decode(envelope)
                try Task.checkCancellation()
                guard let self, self.epoch == currentEpoch, self.visible, self.enabled,
                      self.isAppActive(), admission.connectionGeneration == self.connectionGeneration,
                      let update = self.session?.completePresentation(decoded, ticket: ticket) else { return }
                if !update.ignored && !update.ended { self.image = decoded.image }
                self.apply(update)
            } catch {
                guard !Task.isCancelled, let self, self.epoch == currentEpoch,
                      let update = self.session?.decodeFailed(ticket: ticket) else { return }
                self.apply(update)
            }
        }
    }

    private func apply(_ update: ScreenPreviewSessionUpdate) {
        if update.ended {
            endLocalWork(stopNotice: update.outgoing.first)
        } else {
            for envelope in update.outgoing { send(envelope) }
        }
        publish()
        scheduleWatchdog()
    }

    private func endLocalWork(stopNotice: PlinkEnvelope?) {
        let previous = snapshot
        epoch = UUID()
        admissionGeneration.set(nil)
        image = nil
        watchdog?.cancel()
        watchdog = nil
        decodeTask?.cancel()
        let pendingSends = Array(sends.values)
        pendingSends.forEach { $0.cancel() }
        sends.removeAll()
        guard let sender, let requestID = previous?.requestID else { return }
        let id = UUID()
        let priorCleanup = cleanupTask
        cleanupID = id
        cleanupTask = Task { [weak self] in
            await priorCleanup?.value
            await sender.cancelScreenWork(requestID: requestID)
            for task in pendingSends { await task.value }
            // Stop is best effort, has no retry, and uses the same bounded sender.
            if let stopNotice { try? await sender.send(stopNotice) }
            guard let self, self.cleanupID == id else { return }
            self.cleanupID = nil
            self.cleanupTask = nil
            self.publish()
        }
    }

    private func send(_ envelope: PlinkEnvelope) {
        guard let sender else { return }
        let id = UUID()
        let currentEpoch = epoch
        sends[id] = Task { [weak self] in
            defer { self?.sends.removeValue(forKey: id) }
            do {
                try Task.checkCancellation()
                guard self?.epoch == currentEpoch else { return }
                try await sender.send(envelope)
            } catch {
                guard !Task.isCancelled, let self, self.epoch == currentEpoch,
                      let requestID = envelope.payload["requestId"]?.stringValue,
                      let update = self.session?.outboundFailed(
                        requestID: requestID, streamID: envelope.payload["streamId"]?.stringValue
                      ) else { return }
                self.apply(update)
            }
        }
    }

    private func scheduleWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        guard let deadline = session?.nextWakeInstant else { return }
        let currentEpoch = epoch
        watchdog = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self, self.epoch == currentEpoch,
                  let update = self.session?.wake() else { return }
            self.apply(update)
        }
    }

    private func publish() {
        snapshot = session?.snapshot()
        let active: Bool
        switch snapshot?.phase {
        case .requesting, .needsConsent, .streaming: active = true
        default: active = false
        }
        canStart = !isShutdown && session != nil && sender != nil && visible && enabled && !active &&
            decodeTask == nil && cleanupTask == nil
        guard enabled else { statusText = "Screen preview is off on this Mac."; return }
        guard let snapshot else { statusText = "Pair your phone to preview its screen."; return }
        switch snapshot.phase {
        case .idle: statusText = "Start a preview, then approve screen sharing on your phone."
        case .requesting: statusText = "Requesting screen sharing from your phone…"
        case .needsConsent: statusText = "Open Plink on your phone and tap Share screen."
        case .streaming:
            statusText = snapshot.isStale ? "Preview paused — waiting for a new frame." :
                (snapshot.hasPresentedFrame ? "Live preview · up to 2 frames per second" : "Waiting for the first frame…")
        case .rejected(let reason): statusText = "Phone declined screen sharing: \(reason.rawValue.replacingOccurrences(of: "_", with: " "))."
        case .stopped(let reason): statusText = "Preview stopped: \(reason.rawValue.replacingOccurrences(of: "_", with: " ")). Start again for new consent."
        }
    }
}

/// Captured on the receiver thread before it publishes bounded work to MainActor.
/// An ambiguous authenticated rejection can never cross a local Start boundary.
final class ScreenPreviewGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?
    func set(_ value: UUID?) { lock.withLock { self.value = value } }
    func current() -> UUID? { lock.withLock { value } }
}

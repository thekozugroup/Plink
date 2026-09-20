import Foundation

public struct ScreenPreviewBinding: Equatable, Sendable {
    public let localDeviceID: String
    public let peerDeviceID: String

    public init(localDeviceID: String, peerDeviceID: String) {
        self.localDeviceID = localDeviceID
        self.peerDeviceID = peerDeviceID
    }
}

public enum ScreenPreviewPhase: Equatable, Sendable {
    case idle
    case requesting
    case needsConsent
    case streaming
    case rejected(ScreenPreviewRejectionReason)
    case stopped(ScreenPreviewStopReason)
}

public struct ScreenPreviewSnapshot: Equatable, Sendable {
    public let generation: UUID?
    public let phase: ScreenPreviewPhase
    public let requestID: String?
    public let streamID: String?
    public let nextIndex: Int
    public let outstandingIndex: Int?
    public let hasPresentedFrame: Bool
    public let lastFrameAge: Duration?
    public let isStale: Bool
}

public struct ScreenFrameTicket: Equatable, Sendable {
    public let generation: UUID
    public let requestID: String
    public let streamID: String
    public let index: Int

    public init(generation: UUID, requestID: String, streamID: String, index: Int) {
        self.generation = generation
        self.requestID = requestID
        self.streamID = streamID
        self.index = index
    }
}

public struct ScreenPreviewSessionUpdate: Sendable {
    public let outgoing: [PlinkEnvelope]
    public let frameEnvelope: PlinkEnvelope?
    public let frameTicket: ScreenFrameTicket?
    public let ignored: Bool
    public let ended: Bool

    public init(
        outgoing: [PlinkEnvelope] = [],
        frameEnvelope: PlinkEnvelope? = nil,
        frameTicket: ScreenFrameTicket? = nil,
        ignored: Bool = false,
        ended: Bool = false
    ) {
        self.outgoing = outgoing
        self.frameEnvelope = frameEnvelope
        self.frameTicket = frameTicket
        self.ignored = ignored
        self.ended = ended
    }
}

/// Mac-side monotonic state machine. It owns no sockets, images, or tasks.
public struct ScreenPreviewSession: Sendable {
    public let binding: ScreenPreviewBinding

    private(set) public var phase: ScreenPreviewPhase = .idle
    private var generation: UUID?
    private var requestID: String?
    private var streamID: String?
    private var nextIndex = 1
    private var outstandingIndex: Int?
    private var decodingIndex: Int?
    private var requestCreatedAt: ContinuousClock.Instant?
    private var initialStateDeadline: ContinuousClock.Instant?
    private var consentDeadline: ContinuousClock.Instant?
    private var firstFrameDeadline: ContinuousClock.Instant?
    private var responseDeadline: ContinuousClock.Instant?
    private var nextPullAt: ContinuousClock.Instant?
    private var lastFrameAt: ContinuousClock.Instant?
    private var hasPresentedFrame = false
    private var staleDeadlinePending = false
    private var consecutiveOversizeResponses = 0

    public init(binding: ScreenPreviewBinding) {
        self.binding = binding
    }

    public mutating func start(now: ContinuousClock.Instant = .now) -> ScreenPreviewSessionUpdate {
        guard !isActive else { return ScreenPreviewSessionUpdate(ignored: true) }
        resetActiveState()
        let newRequestID = UUID().uuidString.lowercased()
        generation = UUID()
        requestID = newRequestID
        phase = .requesting
        requestCreatedAt = now
        initialStateDeadline = now.advanced(by: ScreenPreviewProtocol.initialStateTimeout)
        consentDeadline = now.advanced(by: ScreenPreviewProtocol.consentTimeout)
        let request = makeEnvelope(.request(requestID: newRequestID))
        return ScreenPreviewSessionUpdate(outgoing: [request])
    }

    public mutating func receive(
        _ envelope: PlinkEnvelope,
        now: ContinuousClock.Instant = .now
    ) throws -> ScreenPreviewSessionUpdate {
        guard ScreenPreviewPayloadPolicy.eventTypes.contains(envelope.type) else {
            return ScreenPreviewSessionUpdate(ignored: true)
        }
        guard envelope.sourceDeviceId == binding.peerDeviceID,
              envelope.targetDeviceId == binding.localDeviceID
        else { return ScreenPreviewSessionUpdate(ignored: true) }

        let message = try ScreenPreviewMessage(envelope: envelope)
        guard let currentRequestID = requestID else { return ScreenPreviewSessionUpdate(ignored: true) }
        let incomingRequestID = Self.requestID(of: message)
        guard incomingRequestID == currentRequestID else { return ScreenPreviewSessionUpdate(ignored: true) }

        if case .stop(_, let incomingStreamID, let reason) = message {
            if let incomingStreamID, incomingStreamID != streamID {
                return ScreenPreviewSessionUpdate(ignored: true)
            }
            phase = .stopped(reason)
            invalidateActiveState(keepPhase: true)
            return ScreenPreviewSessionUpdate(ended: true)
        }

        if (phase == .requesting && initialStateDeadline.map { now >= $0 } == true) ||
            (phase == .needsConsent && consentDeadline.map { now >= $0 } == true) ||
            (phase == .streaming && responseDeadline.map { now >= $0 } == true) ||
            (phase == .streaming && !hasPresentedFrame && firstFrameDeadline.map { now >= $0 } == true) {
            return terminate(.timeout, notifyPeer: true)
        }

        switch message {
        case .needsConsent:
            guard phase == .requesting || phase == .needsConsent else {
                return terminate(.protocolError, notifyPeer: true)
            }
            phase = .needsConsent
            initialStateDeadline = nil
            return ScreenPreviewSessionUpdate()

        case .started(_, let incomingStreamID):
            guard phase == .requesting || phase == .needsConsent else {
                return terminate(.protocolError, notifyPeer: true)
            }
            phase = .streaming
            streamID = incomingStreamID
            initialStateDeadline = nil
            consentDeadline = nil
            firstFrameDeadline = now.advanced(by: ScreenPreviewProtocol.firstFrameTimeout)
            return enqueuePull(now: now)

        case .rejected(_, let reason):
            guard phase == .requesting || phase == .needsConsent else {
                return terminate(.protocolError, notifyPeer: true)
            }
            phase = .rejected(reason)
            invalidateActiveState(keepPhase: true)
            return ScreenPreviewSessionUpdate(ended: true)

        case .frame(let frame):
            guard phase == .streaming else { return terminate(.protocolError, notifyPeer: true) }
            guard frame.streamID == streamID else { return ScreenPreviewSessionUpdate(ignored: true) }
            guard outstandingIndex == frame.index, decodingIndex == nil,
                  let generation, let streamID else {
                return terminate(.protocolError, notifyPeer: true)
            }
            decodingIndex = frame.index
            let ticket = ScreenFrameTicket(
                generation: generation,
                requestID: currentRequestID,
                streamID: streamID,
                index: frame.index
            )
            return ScreenPreviewSessionUpdate(frameEnvelope: envelope, frameTicket: ticket)

        case .idle(_, let incomingStreamID, let index, let reason):
            guard phase == .streaming else { return terminate(.protocolError, notifyPeer: true) }
            guard incomingStreamID == streamID else { return ScreenPreviewSessionUpdate(ignored: true) }
            guard outstandingIndex == index, decodingIndex == nil else {
                return terminate(.protocolError, notifyPeer: true)
            }
            outstandingIndex = nil
            responseDeadline = nil
            if reason == .frameTooLarge {
                consecutiveOversizeResponses += 1
                if consecutiveOversizeResponses >= 3 {
                    return terminate(.captureError, notifyPeer: true)
                }
            } else {
                consecutiveOversizeResponses = 0
            }
            guard advanceIndex() else { return terminate(.protocolError, notifyPeer: true) }
            nextPullAt = now.advanced(by: ScreenPreviewProtocol.minimumPullInterval)
            return ScreenPreviewSessionUpdate()

        case .stop:
            return ScreenPreviewSessionUpdate(ignored: true)

        case .request, .pull:
            return terminate(.protocolError, notifyPeer: true)
        }
    }

    public mutating func completePresentation(
        _ frame: DecodedScreenFrame,
        ticket: ScreenFrameTicket,
        now: ContinuousClock.Instant = .now
    ) -> ScreenPreviewSessionUpdate {
        guard ticketMatchesCurrent(ticket), decodingIndex == ticket.index else {
            return ScreenPreviewSessionUpdate(ignored: true)
        }
        guard frame.requestID == ticket.requestID, frame.streamID == ticket.streamID,
              frame.index == ticket.index,
              responseDeadline.map({ now < $0 }) == true,
              hasPresentedFrame || firstFrameDeadline.map({ now < $0 }) == true
        else { return terminate(.timeout, notifyPeer: true) }

        outstandingIndex = nil
        decodingIndex = nil
        responseDeadline = nil
        firstFrameDeadline = nil
        hasPresentedFrame = true
        lastFrameAt = now
        staleDeadlinePending = true
        consecutiveOversizeResponses = 0
        guard advanceIndex() else { return terminate(.protocolError, notifyPeer: true) }
        nextPullAt = now.advanced(by: ScreenPreviewProtocol.minimumPullInterval)
        return ScreenPreviewSessionUpdate()
    }

    public mutating func decodeFailed(
        ticket: ScreenFrameTicket,
        now: ContinuousClock.Instant = .now
    ) -> ScreenPreviewSessionUpdate {
        guard ticketMatchesCurrent(ticket), decodingIndex == ticket.index else {
            return ScreenPreviewSessionUpdate(ignored: true)
        }
        return terminate(.protocolError, notifyPeer: true)
    }

    public mutating func receiveAuthenticatedRejection(
        _ rejection: AuthenticatedScreenProtocolRejection
    ) -> ScreenPreviewSessionUpdate {
        guard isActive, rejection.peerDeviceID == binding.peerDeviceID else {
            return ScreenPreviewSessionUpdate(ignored: true)
        }
        if let rejectionRequestID = rejection.requestID, rejectionRequestID != requestID {
            return ScreenPreviewSessionUpdate(ignored: true)
        }
        if let rejectionStreamID = rejection.streamID, let streamID, rejectionStreamID != streamID {
            return ScreenPreviewSessionUpdate(ignored: true)
        }
        return terminate(.protocolError, notifyPeer: true)
    }

    public mutating func outboundFailed(
        requestID failedRequestID: String,
        streamID failedStreamID: String?
    ) -> ScreenPreviewSessionUpdate {
        guard isActive, failedRequestID == requestID,
              failedStreamID == nil || streamID == nil || failedStreamID == streamID
        else { return ScreenPreviewSessionUpdate(ignored: true) }
        return terminate(.timeout, notifyPeer: false)
    }

    public mutating func wake(now: ContinuousClock.Instant = .now) -> ScreenPreviewSessionUpdate {
        guard isActive else { return ScreenPreviewSessionUpdate() }
        if let initialStateDeadline, now >= initialStateDeadline {
            return terminate(.timeout, notifyPeer: true)
        }
        if let consentDeadline, phase == .needsConsent, now >= consentDeadline {
            return terminate(.timeout, notifyPeer: true)
        }
        if let firstFrameDeadline, !hasPresentedFrame, now >= firstFrameDeadline {
            return terminate(.timeout, notifyPeer: true)
        }
        if let responseDeadline, now >= responseDeadline {
            return terminate(.timeout, notifyPeer: true)
        }
        if staleDeadlinePending, let lastFrameAt,
           now >= lastFrameAt.advanced(by: ScreenPreviewProtocol.staleAfter) {
            staleDeadlinePending = false
            return ScreenPreviewSessionUpdate()
        }
        if phase == .streaming, outstandingIndex == nil, decodingIndex == nil,
           let nextPullAt, now >= nextPullAt {
            return enqueuePull(now: now)
        }
        return ScreenPreviewSessionUpdate()
    }

    public mutating func stop(
        reason: ScreenPreviewStopReason,
        notifyPeer: Bool = true
    ) -> ScreenPreviewSessionUpdate {
        guard isActive else {
            if phase == .idle { phase = .stopped(reason) }
            return ScreenPreviewSessionUpdate(ended: true)
        }
        return terminate(reason, notifyPeer: notifyPeer)
    }

    public func snapshot(now: ContinuousClock.Instant = .now) -> ScreenPreviewSnapshot {
        let age = lastFrameAt.map { $0.duration(to: now) }
        return ScreenPreviewSnapshot(
            generation: generation,
            phase: phase,
            requestID: requestID,
            streamID: streamID,
            nextIndex: nextIndex,
            outstandingIndex: outstandingIndex,
            hasPresentedFrame: hasPresentedFrame,
            lastFrameAge: age,
            isStale: age.map { $0 >= ScreenPreviewProtocol.staleAfter } ?? false
        )
    }

    public var nextWakeInstant: ContinuousClock.Instant? {
        let candidates = [
            initialStateDeadline,
            phase == .needsConsent ? consentDeadline : nil,
            !hasPresentedFrame ? firstFrameDeadline : nil,
            responseDeadline,
            outstandingIndex == nil && decodingIndex == nil ? nextPullAt : nil,
            staleDeadlinePending ? lastFrameAt.map { $0.advanced(by: ScreenPreviewProtocol.staleAfter) } : nil,
        ].compactMap { $0 }
        return candidates.min()
    }

    private var isActive: Bool {
        switch phase {
        case .requesting, .needsConsent, .streaming: return true
        default: return false
        }
    }

    private mutating func enqueuePull(now: ContinuousClock.Instant) -> ScreenPreviewSessionUpdate {
        guard phase == .streaming, outstandingIndex == nil, decodingIndex == nil,
              let requestID, let streamID else {
            return terminate(.protocolError, notifyPeer: true)
        }
        let index = nextIndex
        outstandingIndex = index
        nextPullAt = nil
        responseDeadline = now.advanced(by: ScreenPreviewProtocol.responseTimeout)
        let pull = makeEnvelope(.pull(requestID: requestID, streamID: streamID, index: index))
        return ScreenPreviewSessionUpdate(outgoing: [pull])
    }

    private mutating func advanceIndex() -> Bool {
        guard nextIndex < Int(Int32.max) else { return false }
        nextIndex += 1
        return true
    }

    private mutating func terminate(
        _ reason: ScreenPreviewStopReason,
        notifyPeer: Bool
    ) -> ScreenPreviewSessionUpdate {
        let stop: PlinkEnvelope?
        if notifyPeer, let requestID {
            stop = makeEnvelope(.stop(requestID: requestID, streamID: streamID, reason: reason))
        } else {
            stop = nil
        }
        phase = .stopped(reason)
        invalidateActiveState(keepPhase: true)
        return ScreenPreviewSessionUpdate(outgoing: stop.map { [$0] } ?? [], ended: true)
    }

    private func makeEnvelope(_ message: ScreenPreviewMessage) -> PlinkEnvelope {
        message.envelope(
            sourceDeviceID: binding.localDeviceID,
            targetDeviceID: binding.peerDeviceID
        )
    }

    private func ticketMatchesCurrent(_ ticket: ScreenFrameTicket) -> Bool {
        generation == ticket.generation && requestID == ticket.requestID &&
            streamID == ticket.streamID && outstandingIndex == ticket.index
    }

    private mutating func invalidateActiveState(keepPhase: Bool) {
        generation = nil
        requestID = nil
        streamID = nil
        outstandingIndex = nil
        decodingIndex = nil
        requestCreatedAt = nil
        initialStateDeadline = nil
        consentDeadline = nil
        firstFrameDeadline = nil
        responseDeadline = nil
        nextPullAt = nil
        lastFrameAt = nil
        hasPresentedFrame = false
        staleDeadlinePending = false
        consecutiveOversizeResponses = 0
        nextIndex = 1
        if !keepPhase { phase = .idle }
    }

    private mutating func resetActiveState() {
        invalidateActiveState(keepPhase: false)
    }

    private static func requestID(of message: ScreenPreviewMessage) -> String {
        switch message {
        case .request(let requestID), .needsConsent(let requestID), .started(let requestID, _),
             .rejected(let requestID, _), .pull(let requestID, _, _),
             .idle(let requestID, _, _, _), .stop(let requestID, _, _): return requestID
        case .frame(let frame): return frame.requestID
        }
    }
}

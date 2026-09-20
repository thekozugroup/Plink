import Foundation

public enum ScreenPreviewProtocol {
    public static let version = 1
    public static let profile = "jpeg-1280-2fps-v1"
    public static let minimumPullInterval: Duration = .milliseconds(500)
    public static let initialStateTimeout: Duration = .seconds(5)
    public static let consentTimeout: Duration = .seconds(60)
    public static let firstFrameTimeout: Duration = .seconds(5)
    public static let responseTimeout: Duration = .seconds(5)
    public static let staleAfter: Duration = .milliseconds(1_500)
    public static let maxLongEdge = 1_280
    public static let maxShortEdge = 720
    public static let maxPixels = 921_600
    public static let maxJPEGBytes = 40_960
    public static let maxBase64Characters = 54_616
    public static let maxControlEnvelopeBytes = 2_048
    public static let maxScreenWireBytes = 98_304
}

public enum ScreenPreviewRejectionReason: String, Codable, CaseIterable, Sendable {
    case denied
    case disabled
    case unsupported
    case busy
    case notReady = "not_ready"
    case timeout
    case captureError = "capture_error"
}

public enum ScreenPreviewIdleReason: String, Codable, CaseIterable, Sendable {
    case noNewFrame = "no_new_frame"
    case frameTooLarge = "frame_too_large"
}

public enum ScreenPreviewStopReason: String, Codable, CaseIterable, Sendable {
    case user
    case disabled
    case locked
    case hidden
    case disconnected
    case timeout
    case consentRevoked = "consent_revoked"
    case captureError = "capture_error"
    case protocolError = "protocol_error"
}

public struct ScreenFramePayload: Equatable, Sendable {
    public let requestID: String
    public let streamID: String
    public let index: Int
    public let width: Int
    public let height: Int
    public let jpegData: Data

    public init(requestID: String, streamID: String, index: Int, width: Int, height: Int, jpegData: Data) {
        self.requestID = requestID
        self.streamID = streamID
        self.index = index
        self.width = width
        self.height = height
        self.jpegData = jpegData
    }
}

public enum ScreenPreviewMessage: Equatable, Sendable {
    case request(requestID: String)
    case needsConsent(requestID: String)
    case started(requestID: String, streamID: String)
    case rejected(requestID: String, reason: ScreenPreviewRejectionReason)
    case pull(requestID: String, streamID: String, index: Int)
    case frame(ScreenFramePayload)
    case idle(requestID: String, streamID: String, index: Int, reason: ScreenPreviewIdleReason)
    case stop(requestID: String, streamID: String?, reason: ScreenPreviewStopReason)

    public init(envelope: PlinkEnvelope) throws {
        guard ScreenPreviewPayloadPolicy.eventTypes.contains(envelope.type) else {
            throw PayloadPolicyError.malformedFrame
        }
        try ScreenPreviewPayloadPolicy.validate(envelope)
        let p = envelope.payload
        guard let requestID = p["requestId"]?.stringValue else {
            throw PayloadPolicyError.malformedFrame
        }
        switch envelope.type {
        case .screenRequest:
            self = .request(requestID: requestID)
        case .screenState:
            guard let state = p["state"]?.stringValue else { throw PayloadPolicyError.malformedFrame }
            switch state {
            case "needs_consent": self = .needsConsent(requestID: requestID)
            case "started":
                guard let streamID = p["streamId"]?.stringValue else { throw PayloadPolicyError.malformedFrame }
                self = .started(requestID: requestID, streamID: streamID)
            case "rejected":
                guard let rawReason = p["reason"]?.stringValue,
                      let reason = ScreenPreviewRejectionReason(rawValue: rawReason)
                else { throw PayloadPolicyError.malformedFrame }
                self = .rejected(
                    requestID: requestID,
                    reason: reason
                )
            default: throw PayloadPolicyError.malformedFrame
            }
        case .screenPull:
            guard let streamID = p["streamId"]?.stringValue,
                  let index = p["index"]?.intValue
            else { throw PayloadPolicyError.malformedFrame }
            self = .pull(
                requestID: requestID,
                streamID: streamID,
                index: index
            )
        case .screenFrame:
            guard let streamID = p["streamId"]?.stringValue,
                  let index = p["index"]?.intValue,
                  let width = p["width"]?.intValue,
                  let height = p["height"]?.intValue,
                  let encoded = p["data"]?.stringValue,
                  let data = Data(base64Encoded: encoded)
            else { throw PayloadPolicyError.malformedFrame }
            self = .frame(ScreenFramePayload(
                requestID: requestID,
                streamID: streamID,
                index: index,
                width: width,
                height: height,
                jpegData: data
            ))
        case .screenIdle:
            guard let streamID = p["streamId"]?.stringValue,
                  let index = p["index"]?.intValue,
                  let rawReason = p["reason"]?.stringValue,
                  let reason = ScreenPreviewIdleReason(rawValue: rawReason)
            else { throw PayloadPolicyError.malformedFrame }
            self = .idle(
                requestID: requestID,
                streamID: streamID,
                index: index,
                reason: reason
            )
        case .screenStop:
            guard let rawReason = p["reason"]?.stringValue,
                  let reason = ScreenPreviewStopReason(rawValue: rawReason)
            else { throw PayloadPolicyError.malformedFrame }
            self = .stop(
                requestID: requestID,
                streamID: p["streamId"]?.stringValue,
                reason: reason
            )
        default: throw PayloadPolicyError.malformedFrame
        }
    }

    public func envelope(
        sourceDeviceID: String,
        targetDeviceID: String,
        id: String = UUID().uuidString.lowercased(),
        sentAt: Date = .now
    ) -> PlinkEnvelope {
        var payload: [String: PayloadValue] = ["v": .int(1)]
        let type: EventType
        switch self {
        case .request(let requestID):
            type = .screenRequest
            payload["requestId"] = .string(requestID)
            payload["profile"] = .string(ScreenPreviewProtocol.profile)
        case .needsConsent(let requestID):
            type = .screenState
            payload["requestId"] = .string(requestID)
            payload["state"] = .string("needs_consent")
        case .started(let requestID, let streamID):
            type = .screenState
            payload["requestId"] = .string(requestID)
            payload["state"] = .string("started")
            payload["streamId"] = .string(streamID)
            payload["profile"] = .string(ScreenPreviewProtocol.profile)
        case .rejected(let requestID, let reason):
            type = .screenState
            payload["requestId"] = .string(requestID)
            payload["state"] = .string("rejected")
            payload["reason"] = .string(reason.rawValue)
        case .pull(let requestID, let streamID, let index):
            type = .screenPull
            payload["requestId"] = .string(requestID)
            payload["streamId"] = .string(streamID)
            payload["index"] = .int(index)
        case .frame(let frame):
            type = .screenFrame
            payload["requestId"] = .string(frame.requestID)
            payload["streamId"] = .string(frame.streamID)
            payload["index"] = .int(frame.index)
            payload["width"] = .int(frame.width)
            payload["height"] = .int(frame.height)
            payload["data"] = .string(frame.jpegData.base64EncodedString())
        case .idle(let requestID, let streamID, let index, let reason):
            type = .screenIdle
            payload["requestId"] = .string(requestID)
            payload["streamId"] = .string(streamID)
            payload["index"] = .int(index)
            payload["reason"] = .string(reason.rawValue)
        case .stop(let requestID, let streamID, let reason):
            type = .screenStop
            payload["requestId"] = .string(requestID)
            if let streamID { payload["streamId"] = .string(streamID) }
            payload["reason"] = .string(reason.rawValue)
        }
        return PlinkEnvelope(
            id: id,
            type: type,
            sentAt: sentAt,
            sourceDeviceId: sourceDeviceID,
            targetDeviceId: targetDeviceID,
            requiresAck: false,
            payload: payload
        )
    }
}

public struct AuthenticatedScreenProtocolRejection: Error, Equatable, Sendable {
    public let peerDeviceID: String
    public let requestID: String?
    public let streamID: String?
    public let reason: ScreenPreviewStopReason

    public init(peerDeviceID: String, requestID: String?, streamID: String?) {
        self.peerDeviceID = peerDeviceID
        self.requestID = requestID
        self.streamID = streamID
        self.reason = .protocolError
    }
}

public final class ScreenPreviewIngressToken: @unchecked Sendable {
    fileprivate let id: UUID
    public let connectionGeneration: UUID
    public let peerDeviceID: String
    public let requestID: String?
    public let streamID: String?
    public let isFrame: Bool

    private let lock = NSLock()
    private var didRelease = false
    private let releaser: @Sendable (UUID) -> Void

    fileprivate init(
        id: UUID,
        connectionGeneration: UUID,
        peerDeviceID: String,
        requestID: String?,
        streamID: String?,
        isFrame: Bool,
        releaser: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.connectionGeneration = connectionGeneration
        self.peerDeviceID = peerDeviceID
        self.requestID = requestID
        self.streamID = streamID
        self.isFrame = isFrame
        self.releaser = releaser
    }

    public func release() {
        lock.lock()
        guard !didRelease else {
            lock.unlock()
            return
        }
        didRelease = true
        lock.unlock()
        releaser(id)
    }

    deinit { release() }
}

/// Bounded admission runs before creating MainActor work or starting ImageIO decode.
public final class ScreenPreviewIngress: @unchecked Sendable {
    private enum Kind: Equatable { case control, frame }
    private struct Admission {
        let generation: UUID
        let kind: Kind
    }
    private struct Bucket {
        var tokens: Double
        var updatedAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var admissions: [UUID: Admission] = [:]
    private var controlBuckets: [String: Bucket] = [:]
    private var frameBuckets: [String: Bucket] = [:]

    public init() {}

    public func admit(
        _ envelope: PlinkEnvelope,
        expectedSourceDeviceID: String,
        expectedTargetDeviceID: String,
        connectionGeneration: UUID
    ) -> ScreenPreviewIngressToken? {
        guard ScreenPreviewPayloadPolicy.eventTypes.contains(envelope.type),
              envelope.sourceDeviceId == expectedSourceDeviceID,
              envelope.targetDeviceId == expectedTargetDeviceID
        else { return nil }
        let kind: Kind = envelope.type == .screenFrame ? .frame : .control
        return admit(
            kind: kind,
            peerDeviceID: expectedSourceDeviceID,
            requestID: envelope.payload["requestId"]?.stringValue,
            streamID: envelope.payload["streamId"]?.stringValue,
            connectionGeneration: connectionGeneration
        )
    }

    public func admit(
        _ rejection: AuthenticatedScreenProtocolRejection,
        expectedPeerDeviceID: String,
        connectionGeneration: UUID
    ) -> ScreenPreviewIngressToken? {
        guard rejection.peerDeviceID == expectedPeerDeviceID else { return nil }
        return admit(
            kind: .control,
            peerDeviceID: expectedPeerDeviceID,
            requestID: rejection.requestID,
            streamID: rejection.streamID,
            connectionGeneration: connectionGeneration
        )
    }

    public func release(_ token: ScreenPreviewIngressToken) {
        token.release()
    }

    private func release(id: UUID) {
        lock.lock()
        admissions.removeValue(forKey: id)
        lock.unlock()
    }

    public func invalidate(connectionGeneration: UUID) {
        lock.lock()
        admissions = admissions.filter { $0.value.generation != connectionGeneration }
        lock.unlock()
    }

    private func admit(
        kind: Kind,
        peerDeviceID: String,
        requestID: String?,
        streamID: String?,
        connectionGeneration: UUID
    ) -> ScreenPreviewIngressToken? {
        let now = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        let pending = admissions.values.reduce(into: 0) { count, admission in
            if admission.kind == kind { count += 1 }
        }
        let allowed: Bool
        switch kind {
        case .control:
            allowed = pending < 2 && consume(
                peer: peerDeviceID, rate: 8, capacity: 4, now: now, buckets: &controlBuckets
            )
        case .frame:
            allowed = pending < 1 && consume(
                peer: peerDeviceID, rate: 2, capacity: 2, now: now, buckets: &frameBuckets
            )
        }
        guard allowed else { return nil }
        let id = UUID()
        admissions[id] = Admission(generation: connectionGeneration, kind: kind)
        return ScreenPreviewIngressToken(
            id: id,
            connectionGeneration: connectionGeneration,
            peerDeviceID: peerDeviceID,
            requestID: requestID,
            streamID: streamID,
            isFrame: kind == .frame,
            releaser: { [weak self] id in self?.release(id: id) }
        )
    }

    private func consume(
        peer: String,
        rate: Double,
        capacity: Double,
        now: ContinuousClock.Instant,
        buckets: inout [String: Bucket]
    ) -> Bool {
        var bucket = buckets[peer] ?? Bucket(tokens: capacity, updatedAt: now)
        let elapsed = bucket.updatedAt.duration(to: now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        bucket.tokens = min(capacity, bucket.tokens + max(0, seconds) * rate)
        bucket.updatedAt = now
        guard bucket.tokens >= 1 else {
            buckets[peer] = bucket
            return false
        }
        bucket.tokens -= 1
        buckets[peer] = bucket
        return true
    }
}

public enum ScreenPreviewPayloadPolicy {
    public static let eventTypes: Set<EventType> = [
        .screenRequest, .screenState, .screenPull, .screenFrame, .screenIdle, .screenStop,
    ]

    public static func validate(_ envelope: PlinkEnvelope) throws {
        guard eventTypes.contains(envelope.type) else { return }
        guard envelope.version == 1, envelope.requiresAck == false,
              canonicalUUIDv4(envelope.id),
              (1...128).contains(envelope.sourceDeviceId.utf8.count),
              (1...128).contains(envelope.targetDeviceId.utf8.count)
        else { throw PayloadPolicyError.malformedFrame }

        let p = envelope.payload
        guard p["v"]?.intValue == 1,
              let requestID = p["requestId"]?.stringValue,
              canonicalUUIDv4(requestID)
        else { throw PayloadPolicyError.malformedFrame }

        switch envelope.type {
        case .screenRequest:
            try fields(p, ["v", "requestId", "profile"])
            guard p["profile"]?.stringValue == ScreenPreviewProtocol.profile else { throw PayloadPolicyError.malformedFrame }
        case .screenState:
            guard let state = p["state"]?.stringValue else { throw PayloadPolicyError.malformedFrame }
            switch state {
            case "needs_consent":
                try fields(p, ["v", "requestId", "state"])
            case "started":
                try fields(p, ["v", "requestId", "state", "streamId", "profile"])
                try streamID(p)
                guard p["profile"]?.stringValue == ScreenPreviewProtocol.profile else { throw PayloadPolicyError.malformedFrame }
            case "rejected":
                try fields(p, ["v", "requestId", "state", "reason"])
                guard let value = p["reason"]?.stringValue,
                      ScreenPreviewRejectionReason(rawValue: value) != nil else { throw PayloadPolicyError.malformedFrame }
            default: throw PayloadPolicyError.malformedFrame
            }
        case .screenPull:
            try fields(p, ["v", "requestId", "streamId", "index"])
            try streamID(p)
            try positiveIndex(p)
        case .screenFrame:
            try fields(p, ["v", "requestId", "streamId", "index", "width", "height", "data"])
            try streamID(p)
            try positiveIndex(p)
            guard let width = p["width"]?.intValue, let height = p["height"]?.intValue,
                  width > 0, height > 0,
                  max(width, height) <= ScreenPreviewProtocol.maxLongEdge,
                  min(width, height) <= ScreenPreviewProtocol.maxShortEdge,
                  width <= ScreenPreviewProtocol.maxPixels / height,
                  width * height <= ScreenPreviewProtocol.maxPixels,
                  let encoded = p["data"]?.stringValue,
                  encoded.utf8.count <= ScreenPreviewProtocol.maxBase64Characters,
                  let bytes = Data(base64Encoded: encoded),
                  (1...ScreenPreviewProtocol.maxJPEGBytes).contains(bytes.count),
                  bytes.base64EncodedString() == encoded
            else { throw PayloadPolicyError.malformedFrame }
            try ScreenFrameDecoder.validateBaselineJPEG(bytes, width: width, height: height)
        case .screenIdle:
            try fields(p, ["v", "requestId", "streamId", "index", "reason"])
            try streamID(p)
            try positiveIndex(p)
            guard let value = p["reason"]?.stringValue,
                  ScreenPreviewIdleReason(rawValue: value) != nil else { throw PayloadPolicyError.malformedFrame }
        case .screenStop:
            var expected: Set<String> = ["v", "requestId", "reason"]
            if p["streamId"] != nil {
                expected.insert("streamId")
                try streamID(p)
            }
            try fields(p, expected)
            guard let value = p["reason"]?.stringValue,
                  ScreenPreviewStopReason(rawValue: value) != nil else { throw PayloadPolicyError.malformedFrame }
        default: return
        }

        if envelope.type != .screenFrame {
            let encoded = try PlinkJSON.encoder(sortedKeys: true).encode(envelope)
            guard encoded.count <= ScreenPreviewProtocol.maxControlEnvelopeBytes else {
                throw PayloadPolicyError.envelopeTooLarge
            }
        }
    }

    /// Preserves integer token spelling and rejects duplicate keys before Codable loses either fact.
    public static func validateRawJSON(_ data: Data) throws {
        guard let parsed = try RawJSONObject(data: data) else {
            if RawJSONObject.serializedScreenType(data) != nil {
                throw PayloadPolicyError.malformedFrame
            }
            return
        }
        guard parsed.isScreenEnvelope else { return }
        let maxBytes = parsed.uniqueString("type") == EventType.screenFrame.rawValue
            ? PayloadPolicy.maxEnvelopeBytes
            : ScreenPreviewProtocol.maxControlEnvelopeBytes
        try parsed.validateScreenLexemes(maxBytes: maxBytes)
    }

    static func rejection(
        fromAuthenticatedPlaintext data: Data,
        sourceDeviceID: String,
        targetDeviceID: String
    ) -> AuthenticatedScreenProtocolRejection? {
        guard let parsed = try? RawJSONObject(data: data), parsed.isScreenEnvelope,
              parsed.uniqueString("sourceDeviceId") == sourceDeviceID,
              parsed.uniqueString("targetDeviceId") == targetDeviceID
        else { return nil }
        let payload = parsed.payloadMembers
        let requestID = payload.flatMap { RawJSONObject.uniqueString("requestId", in: $0) }
            .flatMap { canonicalUUIDv4($0) ? $0 : nil }
        let streamID = payload.flatMap { RawJSONObject.uniqueString("streamId", in: $0) }
            .flatMap { canonicalUUIDv4($0) ? $0 : nil }
        return AuthenticatedScreenProtocolRejection(
            peerDeviceID: sourceDeviceID,
            requestID: requestID,
            streamID: streamID
        )
    }

    public static func canonicalUUIDv4(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36, bytes[8] == 45, bytes[13] == 45, bytes[18] == 45, bytes[23] == 45,
              bytes[14] == 52, [56, 57, 97, 98].contains(bytes[19]),
              UUID(uuidString: value)?.uuidString.lowercased() == value
        else { return false }
        return true
    }

    private static func fields(_ payload: [String: PayloadValue], _ expected: Set<String>) throws {
        guard Set(payload.keys) == expected else { throw PayloadPolicyError.malformedFrame }
    }

    private static func streamID(_ payload: [String: PayloadValue]) throws {
        guard let value = payload["streamId"]?.stringValue, canonicalUUIDv4(value) else {
            throw PayloadPolicyError.malformedFrame
        }
    }

    private static func positiveIndex(_ payload: [String: PayloadValue]) throws {
        guard let value = payload["index"]?.intValue, (1...Int(Int32.max)).contains(value) else {
            throw PayloadPolicyError.malformedFrame
        }
    }
}

private struct RawJSONObject {
    typealias Member = (key: String, value: [String])
    let data: Data
    let tokens: [String]
    let rootMembers: [Member]
    let matchedRanges: [NSRange]

    init?(data: Data) throws {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #""(?:[^"\\]|\\.)*"|-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\]:,]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        let tokens = matches.map { ns.substring(with: $0.range) }
        guard let members = try? Self.members(tokens) else { return nil }
        self.data = data
        self.tokens = tokens
        self.rootMembers = members
        self.matchedRanges = matches.map(\.range)
    }

    var isScreenEnvelope: Bool {
        rootMembers.contains { member in
            member.key == "type" && member.value.count == 1 &&
                ScreenPreviewPayloadPolicy.eventTypes.map(\.rawValue).contains(Self.string(member.value[0]) ?? "")
        }
    }

    var payloadMembers: [Member]? {
        let matches = rootMembers.filter { $0.key == "payload" }
        guard matches.count == 1 else { return nil }
        return try? Self.members(matches[0].value)
    }

    func uniqueString(_ key: String) -> String? { Self.uniqueString(key, in: rootMembers) }

    static func uniqueString(_ key: String, in members: [Member]) -> String? {
        let matches = members.filter { $0.key == key }
        guard matches.count == 1, matches[0].value.count == 1 else { return nil }
        return string(matches[0].value[0])
    }

    static func serializedScreenType(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let type = root["type"] as? String,
              ScreenPreviewPayloadPolicy.eventTypes.contains(where: { $0.rawValue == type })
        else { return nil }
        return type
    }

    func validateScreenLexemes(maxBytes: Int) throws {
        guard data.count <= maxBytes, Set(rootMembers.map(\.key)).count == rootMembers.count,
              Set(rootMembers.map(\.key)) == Set([
                  "version", "id", "type", "sentAt", "sourceDeviceId", "targetDeviceId", "requiresAck", "payload",
              ]),
              uniqueInteger("version") == 1,
              uniqueToken("requiresAck") == "false",
              uniqueString("sentAt").map(PlinkJSON.isCanonicalTimestamp) == true,
              let raw = String(data: data, encoding: .utf8)
        else { throw PayloadPolicyError.malformedFrame }
        let ns = raw as NSString
        var end = 0
        for range in matchedRanges {
            let gap = ns.substring(with: NSRange(location: end, length: range.location - end))
            guard gap.utf8.allSatisfy({ [9, 10, 13, 32].contains($0) }) else {
                throw PayloadPolicyError.malformedFrame
            }
            end = NSMaxRange(range)
        }
        guard ns.substring(from: end).utf8.allSatisfy({ [9, 10, 13, 32].contains($0) }),
              let payload = payloadMembers,
              Set(payload.map(\.key)).count == payload.count
        else { throw PayloadPolicyError.malformedFrame }
        for member in payload where ["v", "index", "width", "height"].contains(member.key) {
            guard member.value.count == 1, Self.isUnsignedInteger(member.value[0]) else {
                throw PayloadPolicyError.malformedFrame
            }
        }
    }

    private static func string(_ token: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(token.utf8))
    }

    private func uniqueToken(_ key: String) -> String? {
        let matches = rootMembers.filter { $0.key == key }
        guard matches.count == 1, matches[0].value.count == 1 else { return nil }
        return matches[0].value[0]
    }

    private func uniqueInteger(_ key: String) -> Int? {
        guard let token = uniqueToken(key), Self.isUnsignedInteger(token) else { return nil }
        return Int(token)
    }

    private static func isUnsignedInteger(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        return !bytes.isEmpty && bytes.count <= 10 && (bytes.count == 1 || bytes[0] != 48) &&
            bytes.allSatisfy { (48...57).contains($0) }
    }

    private static func members(_ tokens: [String]) throws -> [Member] {
        guard tokens.first == "{", tokens.last == "}" else { throw PayloadPolicyError.malformedFrame }
        var result: [Member] = []
        var i = 1
        while i < tokens.count - 1 {
            guard let key = string(tokens[i]), i + 2 < tokens.count, tokens[i + 1] == ":" else {
                throw PayloadPolicyError.malformedFrame
            }
            i += 2
            let start = i
            var depth = 0
            while i < tokens.count {
                let token = tokens[i]
                if depth == 0 && (token == "," || token == "}") { break }
                if token == "{" || token == "[" { depth += 1 }
                if token == "}" || token == "]" { depth -= 1 }
                guard depth >= 0 else { throw PayloadPolicyError.malformedFrame }
                i += 1
            }
            guard i > start, i < tokens.count, depth == 0 else { throw PayloadPolicyError.malformedFrame }
            result.append((key, Array(tokens[start..<i])))
            if tokens[i] == "," {
                i += 1
                guard i < tokens.count - 1 else { throw PayloadPolicyError.malformedFrame }
            } else {
                break
            }
        }
        return result
    }
}

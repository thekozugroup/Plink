import Darwin
import Foundation
import Security

public enum ReconnectProtocolError: Error, Equatable, Sendable {
    case malformedJSON
    case duplicateField(String)
    case unknownField(String)
    case missingField(String)
    case invalidField(String)
    case unsupportedEvent
    case plaintextTooLarge
    case encryptedFrameTooLarge
    case randomUnavailable(OSStatus)
}

public struct ReconnectValidationPolicy: Sendable, Equatable {
    public static let production = ReconnectValidationPolicy()

    public let allowedPorts: Set<UInt16>
    public let allowsLoopback: Bool

    public init(allowedPorts: Set<UInt16> = [45_731], allowsLoopback: Bool = false) {
        self.allowedPorts = allowedPorts
        self.allowsLoopback = allowsLoopback
    }
}

public struct IPv4Endpoint: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) throws {
        guard Self.parseAddress(address) != nil, port > 0 else {
            throw ReconnectProtocolError.invalidField("endpoint")
        }
        self.address = address
        self.port = port
    }

    public init(_ value: String) throws {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0 else {
            throw ReconnectProtocolError.invalidField("endpoint")
        }
        try self.init(address: String(parts[0]), port: port)
        guard description == value else { throw ReconnectProtocolError.invalidField("endpoint") }
    }

    public var description: String { "\(address):\(port)" }

    public var numericAddress: UInt32 {
        Self.parseAddress(address)!
    }

    static func parseAddress(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber),
                  let byte = UInt8(part), String(byte) == String(part) else { return nil }
            result = (result << 8) | UInt32(byte)
        }
        return result
    }
}

public struct ReconnectInterfaceSnapshot: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let index: UInt32
    public let localIPv4: String
    public let prefixLength: Int
    public let up: Bool
    public let loopback: Bool
    public let pointToPoint: Bool
    public let broadcast: Bool
    public let vpn: Bool
    public let matchingAndroidNetwork: Bool

    public init(
        name: String,
        index: UInt32,
        localIPv4: String,
        prefixLength: Int,
        up: Bool,
        loopback: Bool,
        pointToPoint: Bool,
        broadcast: Bool,
        vpn: Bool,
        matchingAndroidNetwork: Bool = true
    ) {
        self.name = name
        self.index = index
        self.localIPv4 = localIPv4
        self.prefixLength = prefixLength
        self.up = up
        self.loopback = loopback
        self.pointToPoint = pointToPoint
        self.broadcast = broadcast
        self.vpn = vpn
        self.matchingAndroidNetwork = matchingAndroidNetwork
    }
}

public struct ReconnectCandidate: Equatable, Hashable, Sendable {
    public let endpoint: IPv4Endpoint
    public let interface: ReconnectInterfaceSnapshot

    public init(endpoint: IPv4Endpoint, interface: ReconnectInterfaceSnapshot) {
        self.endpoint = endpoint
        self.interface = interface
    }
}

public enum ReconnectCandidatePolicy {
    public static func candidate(
        endpoint value: String,
        interface: ReconnectInterfaceSnapshot,
        validation: ReconnectValidationPolicy = .production
    ) -> ReconnectCandidate? {
        guard let endpoint = try? IPv4Endpoint(value), validation.allowedPorts.contains(endpoint.port),
              interface.up, !interface.pointToPoint, !interface.vpn,
              interface.index > 0, !interface.name.isEmpty,
              let local = IPv4Endpoint.parseAddress(interface.localIPv4),
              (1...30).contains(interface.prefixLength) else { return nil }
        if !validation.allowsLoopback, interface.loopback { return nil }
        let peer = endpoint.numericAddress
        if validation.allowsLoopback, interface.loopback,
           local == 0x7f00_0001, peer == 0x7f00_0001 {
            return ReconnectCandidate(endpoint: endpoint, interface: interface)
        }
        guard interface.broadcast, !interface.loopback,
              isAllowedLocalAddress(local), isAllowedLocalAddress(peer) else { return nil }
        let mask = UInt32.max << UInt32(32 - interface.prefixLength)
        let network = local & mask
        let broadcast = network | ~mask
        guard peer & mask == network, peer != local, peer != network, peer != broadcast else { return nil }
        return ReconnectCandidate(endpoint: endpoint, interface: interface)
    }

    public static func currentInterfaces() -> [ReconnectInterfaceSnapshot] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var output: [ReconnectInterfaceSnapshot] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let local = string(from: address), let maskAddress = item.ifa_netmask,
                  let mask = numericAddress(from: maskAddress) else { continue }
            let name = String(cString: item.ifa_name)
            let flags = Int32(item.ifa_flags)
            let interfaceIndex = name.withCString { if_nametoindex($0) }
            output.append(ReconnectInterfaceSnapshot(
                name: name,
                index: interfaceIndex,
                localIPv4: local,
                prefixLength: mask.nonzeroBitCount,
                up: flags & IFF_UP != 0,
                loopback: flags & IFF_LOOPBACK != 0,
                pointToPoint: flags & IFF_POINTOPOINT != 0,
                broadcast: flags & IFF_BROADCAST != 0,
                vpn: name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("tap") ||
                    name.hasPrefix("ppp") || name.hasPrefix("ipsec")
            ))
        }
        return output
    }

    private static func isAllowedLocalAddress(_ address: UInt32) -> Bool {
        address & 0xff00_0000 == 0x0a00_0000 ||
            address & 0xfff0_0000 == 0xac10_0000 ||
            address & 0xffff_0000 == 0xc0a8_0000 ||
            address & 0xffff_0000 == 0xa9fe_0000
    }

    private static func string(from address: UnsafePointer<sockaddr>) -> String? {
        var source = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &source, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func numericAddress(from address: UnsafePointer<sockaddr>) -> UInt32? {
        guard address.pointee.sa_family == UInt8(AF_INET) else { return nil }
        let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        return UInt32(bigEndian: value)
    }
}

public struct ReconnectMessage: Equatable, Sendable {
    public let type: EventType
    public let conditional: Bool
    public let m: String
    public let p: String?
    public let r: String?
    public let mac: IPv4Endpoint
    public let phone: IPv4Endpoint

    public init(_ envelope: PlinkEnvelope, validation: ReconnectValidationPolicy = .production) throws {
        try ReconnectPayloadPolicy.validate(envelope, validation: validation)
        type = envelope.type
        conditional = envelope.payload["v"]?.intValue == 2
        m = envelope.payload["m"]!.stringValue!
        p = envelope.payload["p"]?.stringValue
        r = envelope.payload["r"]?.stringValue
        mac = try IPv4Endpoint(envelope.payload["mac"]!.stringValue!)
        phone = try IPv4Endpoint(envelope.payload["phone"]!.stringValue!)
    }

    public func envelope(source: String, target: String, id: String = UUID().uuidString.lowercased()) -> PlinkEnvelope {
        var payload: [String: PayloadValue] = [
            "v": .int(conditional ? 2 : 1), "m": .string(m), "mac": .string(mac.description), "phone": .string(phone.description)
        ]
        if conditional {
            payload["domain"] = .string("plink.reconnect.recovery")
            payload["mode"] = .string("conditional-unadmitted")
        }
        if let p { payload["p"] = .string(p) }
        if let r { payload["r"] = .string(r) }
        return PlinkEnvelope(id: id, type: type, sentAt: .now, sourceDeviceId: source,
            targetDeviceId: target, requiresAck: false, payload: payload)
    }
}

public enum ReconnectNonce {
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw ReconnectProtocolError.randomUnavailable(status) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum ReconnectPayloadPolicy {
    public static let eventTypes: Set<EventType> = [
        .reconnectHello, .reconnectChallenge, .reconnectProof, .reconnectReverse,
        .reconnectReverseProof, .reconnectReady, .reconnectCommit, .reconnectDone
    ]

    public static func validateRawJSON(
        _ data: Data,
        validation: ReconnectValidationPolicy = .production
    ) throws {
        guard data.count <= 2_048 else { throw ReconnectProtocolError.plaintextTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ReconnectProtocolError.malformedJSON }
        var parser = StrictJSONParser(text)
        let root = try parser.parse()
        let object = try root.objectValue()
        try exactKeys(object, expected: [
            "version", "id", "type", "sentAt", "sourceDeviceId", "targetDeviceId", "requiresAck", "payload"
        ])
        guard try object.required("version").numberValue() == "1" else {
            throw ReconnectProtocolError.invalidField("version")
        }
        try validateEnvelopeID(try object.required("id").stringValue())
        try validateID(try object.required("sourceDeviceId").stringValue(), name: "sourceDeviceId")
        try validateID(try object.required("targetDeviceId").stringValue(), name: "targetDeviceId")
        guard try object.required("requiresAck").boolValue() == false else {
            throw ReconnectProtocolError.invalidField("requiresAck")
        }
        let sentAt = try object.required("sentAt").stringValue()
        guard PlinkJSON.isCanonicalTimestamp(sentAt) else { throw ReconnectProtocolError.invalidField("sentAt") }
        let type = try eventType(try object.required("type").stringValue())
        let payload = try object.required("payload").objectValue()
        try validatePayload(payload, type: type, validation: validation)
    }

    public static func validate(
        _ envelope: PlinkEnvelope,
        validation: ReconnectValidationPolicy = .production,
        plaintextBytes: Int? = nil,
        encryptedBytes: Int? = nil
    ) throws {
        guard eventTypes.contains(envelope.type) else { return }
        if let plaintextBytes, plaintextBytes > 2_048 { throw ReconnectProtocolError.plaintextTooLarge }
        if let encryptedBytes, encryptedBytes > 4_096 { throw ReconnectProtocolError.encryptedFrameTooLarge }
        guard envelope.version == 1, envelope.requiresAck == false else {
            throw ReconnectProtocolError.invalidField("envelope")
        }
        try validateEnvelopeID(envelope.id)
        try validateID(envelope.sourceDeviceId, name: "sourceDeviceId")
        try validateID(envelope.targetDeviceId, name: "targetDeviceId")
        let version = envelope.payload["v"]?.intValue
        guard version == 1 || version == 2 else { throw ReconnectProtocolError.invalidField("v") }
        let expected = expectedPayloadKeys(envelope.type, conditional: version == 2)
        guard Set(envelope.payload.keys) == expected else { throw ReconnectProtocolError.invalidField("payload") }
        if version == 2 {
            guard envelope.payload["domain"]?.stringValue == "plink.reconnect.recovery",
                  envelope.payload["mode"]?.stringValue == "conditional-unadmitted" else {
                throw ReconnectProtocolError.invalidField("mode")
            }
        }
        for key in ["m", "p", "r"] where expected.contains(key) {
            guard let value = envelope.payload[key]?.stringValue, isCanonicalNonce(value) else {
                throw ReconnectProtocolError.invalidField(key)
            }
        }
        for key in ["mac", "phone"] {
            guard let value = envelope.payload[key]?.stringValue,
                  let endpoint = try? IPv4Endpoint(value), validation.allowedPorts.contains(endpoint.port),
                  endpointAllowed(endpoint, validation: validation) else {
                throw ReconnectProtocolError.invalidField(key)
            }
        }
    }

    public static func validateEncryptedFrame(
        issuedAt: Date,
        decodedIssuedAtLexeme: String? = nil,
        rawJSON: Data?
    ) throws {
        guard issuedAt.timeIntervalSince1970.rounded() == issuedAt.timeIntervalSince1970 else {
            throw ReconnectProtocolError.invalidField("issuedAt")
        }
        guard let rawJSON else {
            if let decodedIssuedAtLexeme,
               !PlinkJSON.isCanonicalTimestamp(decodedIssuedAtLexeme) {
                throw ReconnectProtocolError.invalidField("issuedAt")
            }
            return
        }
        guard rawJSON.count <= 4_096 else { throw ReconnectProtocolError.encryptedFrameTooLarge }
        guard let text = String(data: rawJSON, encoding: .utf8) else {
            throw ReconnectProtocolError.malformedJSON
        }
        var parser = StrictJSONParser(text)
        let object = try parser.parse().objectValue()
        try exactKeys(object, expected: [
            "version", "sequence", "nonce", "issuedAt", "sourceDeviceId", "targetDeviceId",
            "cipherText", "signature"
        ])
        guard try object.required("version").numberValue() == "1" else {
            throw ReconnectProtocolError.invalidField("version")
        }
        let sequenceToken = try object.required("sequence").numberValue()
        guard let sequence = Int64(sequenceToken), sequence > 0, String(sequence) == sequenceToken else {
            throw ReconnectProtocolError.invalidField("sequence")
        }
        guard !(try object.required("nonce").stringValue()).isEmpty,
              !(try object.required("cipherText").stringValue()).isEmpty,
              !(try object.required("signature").stringValue()).isEmpty else {
            throw ReconnectProtocolError.invalidField("frame")
        }
        try validateID(try object.required("sourceDeviceId").stringValue(), name: "sourceDeviceId")
        try validateID(try object.required("targetDeviceId").stringValue(), name: "targetDeviceId")
        guard PlinkJSON.isCanonicalTimestamp(try object.required("issuedAt").stringValue()) else {
            throw ReconnectProtocolError.invalidField("issuedAt")
        }
    }

    private static func validatePayload(
        _ payload: [String: StrictJSONValue],
        type: EventType,
        validation: ReconnectValidationPolicy
    ) throws {
        let version = try payload.required("v").numberValue()
        guard version == "1" || version == "2" else {
            throw ReconnectProtocolError.invalidField("v")
        }
        try exactKeys(payload, expected: expectedPayloadKeys(type, conditional: version == "2"))
        if version == "2" {
            guard try payload.required("domain").stringValue() == "plink.reconnect.recovery",
                  try payload.required("mode").stringValue() == "conditional-unadmitted" else {
                throw ReconnectProtocolError.invalidField("mode")
            }
        }
        for key in ["m", "p", "r"] where payload[key] != nil {
            guard isCanonicalNonce(try payload.required(key).stringValue()) else {
                throw ReconnectProtocolError.invalidField(key)
            }
        }
        for key in ["mac", "phone"] {
            let endpoint = try IPv4Endpoint(try payload.required(key).stringValue())
            guard validation.allowedPorts.contains(endpoint.port), endpointAllowed(endpoint, validation: validation) else {
                throw ReconnectProtocolError.invalidField(key)
            }
        }
    }

    private static func eventType(_ value: String) throws -> EventType {
        guard let type = EventType(rawValue: value), eventTypes.contains(type) else {
            throw ReconnectProtocolError.unsupportedEvent
        }
        return type
    }

    private static func expectedPayloadKeys(_ type: EventType, conditional: Bool = false) -> Set<String> {
        let extensionKeys: Set<String> = conditional ? ["domain", "mode"] : []
        switch type {
        case .reconnectHello: return Set(["v", "m", "mac", "phone"]).union(extensionKeys)
        case .reconnectChallenge, .reconnectProof: return Set(["v", "m", "p", "mac", "phone"]).union(extensionKeys)
        case .reconnectReverse, .reconnectReverseProof, .reconnectReady, .reconnectCommit, .reconnectDone:
            return Set(["v", "m", "p", "r", "mac", "phone"]).union(extensionKeys)
        default: return []
        }
    }

    private static func validateID(_ value: String, name: String) throws {
        guard (1...128).contains(value.utf8.count) else { throw ReconnectProtocolError.invalidField(name) }
    }

    private static func validateEnvelopeID(_ value: String) throws {
        guard value.utf8.count == 36,
              value == value.lowercased(),
              UUID(uuidString: value)?.uuidString.lowercased() == value,
              value[value.index(value.startIndex, offsetBy: 14)] == "4",
              "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)]) else {
            throw ReconnectProtocolError.invalidField("id")
        }
    }

    private static func endpointAllowed(_ endpoint: IPv4Endpoint, validation: ReconnectValidationPolicy) -> Bool {
        let address = endpoint.numericAddress
        if validation.allowsLoopback, address == 0x7f00_0001 { return true }
        return address & 0xff00_0000 == 0x0a00_0000 ||
            address & 0xfff0_0000 == 0xac10_0000 ||
            address & 0xffff_0000 == 0xc0a8_0000 ||
            address & 0xffff_0000 == 0xa9fe_0000
    }

    private static func isCanonicalNonce(_ value: String) -> Bool {
        guard value.utf8.count == 43,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return false }
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded.append("=")
        guard let bytes = Data(base64Encoded: padded), bytes.count == 32 else { return false }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") == value
    }

    private static func exactKeys(_ object: [String: StrictJSONValue], expected: Set<String>) throws {
        if let unknown = object.keys.first(where: { !expected.contains($0) }) {
            throw ReconnectProtocolError.unknownField(unknown)
        }
        if let missing = expected.first(where: { object[$0] == nil }) {
            throw ReconnectProtocolError.missingField(missing)
        }
    }
}

// Shared lexical reader; reconnect validation remains unchanged.
enum StrictJSONValue {
    case object([String: StrictJSONValue])
    case array([StrictJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    func objectValue() throws -> [String: StrictJSONValue] {
        guard case .object(let value) = self else { throw ReconnectProtocolError.malformedJSON }
        return value
    }

    func stringValue() throws -> String {
        guard case .string(let value) = self else { throw ReconnectProtocolError.malformedJSON }
        return value
    }

    func numberValue() throws -> String {
        guard case .number(let value) = self else { throw ReconnectProtocolError.malformedJSON }
        return value
    }

    func boolValue() throws -> Bool {
        guard case .bool(let value) = self else { throw ReconnectProtocolError.malformedJSON }
        return value
    }
}

private extension Dictionary where Key == String, Value == StrictJSONValue {
    func required(_ key: String) throws -> StrictJSONValue {
        guard let value = self[key] else { throw ReconnectProtocolError.missingField(key) }
        return value
    }
}

struct StrictJSONParser {
    private let scalars: [UnicodeScalar]
    private var index = 0

    init(_ text: String) { scalars = Array(text.unicodeScalars) }

    mutating func parse() throws -> StrictJSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == scalars.count else { throw ReconnectProtocolError.malformedJSON }
        return value
    }

    private mutating func parseValue() throws -> StrictJSONValue {
        guard let scalar = peek else { throw ReconnectProtocolError.malformedJSON }
        switch scalar.value {
        case 0x7b: return try parseObject()
        case 0x5b: return try parseArray()
        case 0x22: return .string(try parseString())
        case 0x74: try consume("true"); return .bool(true)
        case 0x66: try consume("false"); return .bool(false)
        case 0x6e: try consume("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func parseObject() throws -> StrictJSONValue {
        try take(0x7b)
        skipWhitespace()
        var result: [String: StrictJSONValue] = [:]
        if consumeIf(0x7d) { return .object(result) }
        while true {
            let key = try parseString()
            guard result[key] == nil else { throw ReconnectProtocolError.duplicateField(key) }
            skipWhitespace(); try take(0x3a); skipWhitespace()
            result[key] = try parseValue()
            skipWhitespace()
            if consumeIf(0x7d) { return .object(result) }
            try take(0x2c); skipWhitespace()
        }
    }

    private mutating func parseArray() throws -> StrictJSONValue {
        try take(0x5b)
        skipWhitespace()
        var result: [StrictJSONValue] = []
        if consumeIf(0x5d) { return .array(result) }
        while true {
            result.append(try parseValue())
            skipWhitespace()
            if consumeIf(0x5d) { return .array(result) }
            try take(0x2c); skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        try take(0x22)
        var output = String.UnicodeScalarView()
        while let scalar = peek {
            index += 1
            if scalar.value == 0x22 { return String(output) }
            if scalar.value < 0x20 { throw ReconnectProtocolError.malformedJSON }
            guard scalar.value == 0x5c else { output.append(scalar); continue }
            guard let escaped = peek else { throw ReconnectProtocolError.malformedJSON }
            index += 1
            switch escaped.value {
            case 0x22, 0x5c, 0x2f: output.append(escaped)
            case 0x62: output.append(UnicodeScalar(0x08)!)
            case 0x66: output.append(UnicodeScalar(0x0c)!)
            case 0x6e: output.append(UnicodeScalar(0x0a)!)
            case 0x72: output.append(UnicodeScalar(0x0d)!)
            case 0x74: output.append(UnicodeScalar(0x09)!)
            case 0x75:
                let first = try hexQuad()
                let value: UInt32
                if (0xd800...0xdbff).contains(first) {
                    try take(0x5c); try take(0x75)
                    let second = try hexQuad()
                    guard (0xdc00...0xdfff).contains(second) else { throw ReconnectProtocolError.malformedJSON }
                    value = 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00
                } else {
                    guard !(0xdc00...0xdfff).contains(first) else { throw ReconnectProtocolError.malformedJSON }
                    value = first
                }
                guard let decoded = UnicodeScalar(value) else { throw ReconnectProtocolError.malformedJSON }
                output.append(decoded)
            default: throw ReconnectProtocolError.malformedJSON
            }
        }
        throw ReconnectProtocolError.malformedJSON
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        _ = consumeIf(0x2d)
        if consumeIf(0x30) {
            if peek.map({ (0x30...0x39).contains($0.value) }) == true { throw ReconnectProtocolError.malformedJSON }
        } else {
            guard consumeDigit(1...9) else { throw ReconnectProtocolError.malformedJSON }
            while consumeDigit(0...9) {}
        }
        if consumeIf(0x2e) {
            guard consumeDigit(0...9) else { throw ReconnectProtocolError.malformedJSON }
            while consumeDigit(0...9) {}
        }
        if peek?.value == 0x65 || peek?.value == 0x45 {
            index += 1
            if peek?.value == 0x2b || peek?.value == 0x2d { index += 1 }
            guard consumeDigit(0...9) else { throw ReconnectProtocolError.malformedJSON }
            while consumeDigit(0...9) {}
        }
        return String(scalars[start..<index].map { Character(String($0)) })
    }

    private mutating func hexQuad() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let scalar = peek else { throw ReconnectProtocolError.malformedJSON }
            index += 1
            let digit: UInt32
            switch scalar.value {
            case 0x30...0x39: digit = scalar.value - 0x30
            case 0x41...0x46: digit = scalar.value - 0x41 + 10
            case 0x61...0x66: digit = scalar.value - 0x61 + 10
            default: throw ReconnectProtocolError.malformedJSON
            }
            result = result * 16 + digit
        }
        return result
    }

    private mutating func consume(_ value: String) throws {
        for scalar in value.unicodeScalars { try take(scalar.value) }
    }

    private mutating func take(_ value: UInt32) throws {
        guard peek?.value == value else { throw ReconnectProtocolError.malformedJSON }
        index += 1
    }

    private mutating func consumeIf(_ value: UInt32) -> Bool {
        guard peek?.value == value else { return false }
        index += 1
        return true
    }

    private mutating func consumeDigit(_ range: ClosedRange<UInt32>) -> Bool {
        guard let value = peek?.value,
              (0x30...0x39).contains(value),
              range.contains(value - 0x30) else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let value = peek?.value, value == 0x20 || value == 0x09 || value == 0x0a || value == 0x0d { index += 1 }
    }

    private var peek: UnicodeScalar? { index < scalars.count ? scalars[index] : nil }
}

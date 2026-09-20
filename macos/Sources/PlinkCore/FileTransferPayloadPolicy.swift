import Foundation

/// Wire validation only. The transfer owner enforces consent, session identity and byte ordering.
public enum FileTransferPayloadPolicy {
    public static let maxFileBytes = 16_777_216
    public static let chunkBytes = 32_768
    public static let eventTypes: Set<EventType> = [.fileOffer, .fileAccept, .fileChunk, .fileProgress, .fileComplete, .fileResult, .fileCancel]
    private static let cancelReasons: Set<String> = ["cancelled", "timeout", "disconnected", "invalid", "storage"]
    private static let errorCodes = cancelReasons.union(["receive_unavailable", "busy"])

    public static func validate(_ envelope: PlinkEnvelope) throws {
        guard eventTypes.contains(envelope.type) else { return }
        let p = envelope.payload
        let id = try text(p, "transferId")
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw PayloadPolicyError.malformedFrame }
        func fields(_ keys: String...) throws {
            guard Set(p.keys) == Set(keys).union(["transferId"]) else { throw PayloadPolicyError.malformedFrame }
        }
        switch envelope.type {
        case .fileOffer:
            try fields("name", "mimeType", "sizeBytes", "sha256", "chunkBytes")
            let name = try text(p, "name")
            guard name.unicodeScalars.contains(where: { !isBlankScalar($0.value) }), name.utf8.count <= 255,
                  name != ".", name != "..", !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0 == "/" || $0 == "\\" }) else { throw PayloadPolicyError.malformedFrame }
            let mime = try text(p, "mimeType")
            guard !mime.trimmingCharacters(in: .whitespaces).isEmpty, mime.utf8.count <= 127,
                  mime.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else { throw PayloadPolicyError.malformedFrame }
            try number(p, "sizeBytes", 0...maxFileBytes)
            try number(p, "chunkBytes", chunkBytes...chunkBytes)
            let digest = try text(p, "sha256")
            guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PayloadPolicyError.malformedFrame }
        case .fileAccept, .fileComplete: try fields()
        case .fileChunk:
            try fields("index", "data")
            try number(p, "index", 0...(maxFileBytes / chunkBytes - 1))
            let raw = try text(p, "data")
            guard raw.utf8.count <= 43_692, let bytes = Data(base64Encoded: raw),
                  (1...chunkBytes).contains(bytes.count), bytes.base64EncodedString() == raw else { throw PayloadPolicyError.malformedFrame }
        case .fileProgress:
            try fields("nextIndex")
            try number(p, "nextIndex", 0...(maxFileBytes / chunkBytes))
        case .fileResult:
            switch try text(p, "status") {
            case "saved": try fields("status")
            case "error":
                try fields("status", "code")
                guard errorCodes.contains(try text(p, "code")) else { throw PayloadPolicyError.malformedFrame }
            default: throw PayloadPolicyError.malformedFrame
            }
        case .fileCancel:
            try fields("reason")
            guard cancelReasons.contains(try text(p, "reason")) else { throw PayloadPolicyError.malformedFrame }
        default: break
        }
    }

    /// File fields use raw unsigned integer tokens, before JSONDecoder can round numbers.
    /// Non-file envelopes keep their existing decoder and numeric behavior.
    public static func validateRawJSON(_ data: Data) throws {
        guard let raw = String(data: data, encoding: .utf8) else { throw PayloadPolicyError.malformedFrame }
        let pattern = #""(?:[^"\\]|\\.)*"|-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\]:,]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        let tokens = matches.map { ns.substring(with: $0.range) }
        let root = try members(tokens)
        let fileTypes = Set(eventTypes.map(\.rawValue))
        guard root.contains(where: { $0.0 == "type" && $0.1.count == 1 &&
            fileTypes.contains((try? JSONDecoder().decode(String.self, from: Data($0.1[0].utf8))) ?? "") }) else { return }
        var end = 0
        for match in matches {
            guard ns.substring(with: NSRange(location: end, length: match.range.location - end))
                .utf8.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { throw PayloadPolicyError.malformedFrame }
            end = NSMaxRange(match.range)
        }
        guard ns.substring(from: end).utf8.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { throw PayloadPolicyError.malformedFrame }
        guard data.count <= 65_536, Set(root.map { $0.0 }).count == root.count,
              let payload = root.first(where: { $0.0 == "payload" }) else { throw PayloadPolicyError.malformedFrame }
        let fields = try members(payload.1)
        guard Set(fields.map { $0.0 }).count == fields.count else { throw PayloadPolicyError.malformedFrame }
        for (key, value) in fields where ["sizeBytes", "chunkBytes", "index", "nextIndex"].contains(key) {
            guard value.count == 1, isIntegerToken(value[0]) else { throw PayloadPolicyError.malformedFrame }
        }
    }

    private static func isIntegerToken(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 8 && (bytes.count == 1 || bytes[0] != 48) &&
            bytes.allSatisfy { (48...57).contains($0) }
    }

    /// Splits object members without interpreting number tokens. JSONDecoder still
    /// validates the complete grammar; this only preserves lexical file constraints.
    private static func members(_ tokens: [String]) throws -> [(String, [String])] {
        guard tokens.first == "{", tokens.last == "}" else { throw PayloadPolicyError.malformedFrame }
        var result: [(String, [String])] = []
        var i = 1
        while i < tokens.count - 1 {
            let key = try JSONDecoder().decode(String.self, from: Data(tokens[i].utf8))
            guard i + 2 < tokens.count, tokens[i + 1] == ":" else { throw PayloadPolicyError.malformedFrame }
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
            } else { break }
        }
        return result
    }

    // Unicode White_Space, fixed shared table (not platform CharacterSet/isBlank).
    private static func isBlankScalar(_ value: UInt32) -> Bool {
        (9...13).contains(value) || value == 0x20 || value == 0x85 || value == 0xA0 ||
        value == 0x1680 || (0x2000...0x200A).contains(value) || value == 0x2028 ||
        value == 0x2029 || value == 0x202F || value == 0x205F || value == 0x3000
    }

    private static func text(_ p: [String: PayloadValue], _ key: String) throws -> String {
        guard let value = p[key]?.stringValue else { throw PayloadPolicyError.malformedFrame }
        return value
    }

    private static func number(_ p: [String: PayloadValue], _ key: String, _ range: ClosedRange<Int>) throws {
        switch p[key] {
        case .int(let value) where range.contains(value): return
        default: throw PayloadPolicyError.malformedFrame
        }
    }
}

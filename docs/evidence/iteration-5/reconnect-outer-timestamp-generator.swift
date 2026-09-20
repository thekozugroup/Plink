// Synthetic compatibility/adversarial vectors. Never use these keys or IVs in an app.
// Run from repository root: swift docs/evidence/iteration-5/reconnect-outer-timestamp-generator.swift OUTPUT
import CryptoKit
import Foundation

let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:
    "shared/protocol/v1/reconnect/encrypted-vectors.json"))) as! [String: Any]
let original = (input["vectors"] as! [[String: Any]])[0]
let originalFrame = original["frame"] as! [String: Any]
let key = Data(base64Encoded: original["sessionKeyBase64"] as! String)!
let plaintext = Data(base64Encoded: original["plaintextBase64"] as! String)!
let iv = Data(base64Encoded: original["ivBase64"] as! String)!
func encode(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}
func authenticatedFrame(timestamp: String) throws -> [String: Any] {
    var frame = originalFrame
    frame["issuedAt"] = timestamp
    let aad = ["1", String(frame["sequence"] as! Int), frame["nonce"] as! String,
               timestamp, frame["sourceDeviceId"] as! String, frame["targetDeviceId"] as! String]
        .joined(separator: "\n")
    let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: SHA256.hash(data: key)),
        nonce: AES.GCM.Nonce(data: iv), authenticating: Data(aad.utf8))
    frame["cipherText"] = sealed.combined!.base64EncodedString()
    frame["signature"] = Data(HMAC<SHA256>.authenticationCode(
        for: Data((aad + "\n" + (frame["cipherText"] as! String)).utf8),
        using: SymmetricKey(data: SHA256.hash(data: Data("plink-frame-hmac".utf8) + key))))
        .base64EncodedString()
    return frame
}
let canonical = "2026-09-20T00:00:00Z"
let regenerated = try authenticatedFrame(timestamp: canonical)
let canonicalBytes = try encode(regenerated)
let originalBytes = try encode(originalFrame)
precondition(canonicalBytes == originalBytes)
let cases: [(String, String, Bool, Bool)] = [
    ("canonical outer timestamp", canonical, true, true),
    ("fractional wire with canonical authentication", "2026-09-20T00:00:00.000Z", false, false),
    ("offset wire with canonical authentication", "2026-09-20T00:00:00+00:00", false, false),
    ("fractional wire with matching authentication", "2026-09-20T00:00:00.000Z", true, false),
    ("fractional instant with matching authentication", "2026-09-20T00:00:00.500Z", true, false),
]
let vectors: [[String: Any]] = try cases.map { name, timestamp, authenticateRaw, valid in
    var frame = authenticateRaw ? try authenticatedFrame(timestamp: timestamp) : originalFrame
    frame["issuedAt"] = timestamp
    return ["name": name, "valid": valid, "sessionKeyBase64": original["sessionKeyBase64"]!,
            "ivBase64": original["ivBase64"]!, "plaintextBase64": original["plaintextBase64"]!,
            "frame": frame, "wire": String(data: try encode(frame), encoding: .utf8)!]
}
let output: [String: Any] = ["schemaVersion": 1,
    "scope": "Supplemental reconnect-only outer timestamp rejection; isolated replay state per vector. Original frozen vectors unchanged.",
    "generator": "docs/evidence/iteration-5/reconnect-outer-timestamp-generator.swift", "vectors": vectors]
try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Generated \(vectors.count) outer timestamp vectors; canonical frame matches prior golden exactly")

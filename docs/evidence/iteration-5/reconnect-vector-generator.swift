// Deterministic synthetic fixtures. Never use this key or these IVs in an app.
// Run from repository root with: swift docs/evidence/iteration-5/reconnect-vector-generator.swift OUTPUT
import CryptoKit
import Foundation

// Check this independent generator against the pre-existing cross-platform fixture.
let prior = try JSONSerialization.jsonObject(with: Data(contentsOf:
    URL(fileURLWithPath: "shared/protocol/v1/screen-preview/cases.json"))) as! [String: Any]
let golden = (prior["encryptedVectors"] as! [[String: Any]])[0]
let goldenFrame = golden["frame"] as! [String: Any]
let goldenKey = Data(base64Encoded: golden["sessionKeyBase64"] as! String)!
let goldenAAD = [String(goldenFrame["version"] as! Int), String(goldenFrame["sequence"] as! Int),
    goldenFrame["nonce"] as! String, goldenFrame["issuedAt"] as! String,
    goldenFrame["sourceDeviceId"] as! String, goldenFrame["targetDeviceId"] as! String].joined(separator: "\n")
let goldenSealed = try AES.GCM.seal(Data((golden["plaintext"] as! String).utf8),
    using: SymmetricKey(data: SHA256.hash(data: goldenKey)),
    nonce: AES.GCM.Nonce(data: Data(base64Encoded: golden["ivBase64"] as! String)!),
    authenticating: Data(goldenAAD.utf8))
precondition(goldenSealed.combined!.base64EncodedString() == goldenFrame["cipherText"] as! String)
let goldenSignature = Data(HMAC<SHA256>.authenticationCode(
    for: Data((goldenAAD + "\n" + (goldenFrame["cipherText"] as! String)).utf8),
    using: SymmetricKey(data: SHA256.hash(data: Data("plink-frame-hmac".utf8) + goldenKey))))
precondition(goldenSignature.base64EncodedString() == goldenFrame["signature"] as! String)

let fixtureURL = URL(fileURLWithPath: "shared/protocol/v1/reconnect/cases.json")
let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
let cases = root["cases"] as! [[String: Any]]
let key = Data(0..<32)
let aes = SymmetricKey(data: SHA256.hash(data: key))
let hmac = SymmetricKey(data: SHA256.hash(data: Data("plink-frame-hmac".utf8) + key))
let timestamp = "2026-09-20T00:00:00Z"
func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}
var vectors: [[String: Any]] = []
func append(name: String, plaintext: Data, source: String, target: String, valid: Bool) throws {
    let sequence = vectors.count + 1
    let nonce = String(format: "00000000-0000-4000-8000-%012d", sequence)
    let iv = Data((0..<12).map { UInt8($0 + sequence) })
    let aad = ["1", String(sequence), nonce, timestamp, source, target].joined(separator: "\n")
    let sealed = try AES.GCM.seal(plaintext, using: aes, nonce: AES.GCM.Nonce(data: iv),
                                  authenticating: Data(aad.utf8))
    let ciphertext = sealed.combined!.base64EncodedString()
    let signature = Data(HMAC<SHA256>.authenticationCode(
        for: Data((aad + "\n" + ciphertext).utf8), using: hmac)).base64EncodedString()
    let frame: [String: Any] = ["version": 1, "sequence": sequence, "nonce": nonce,
        "issuedAt": timestamp, "sourceDeviceId": source, "targetDeviceId": target,
        "cipherText": ciphertext, "signature": signature]
    vectors.append(["name": name, "valid": valid, "sessionKeyBase64": key.base64EncodedString(),
        "ivBase64": iv.base64EncodedString(), "plaintextBase64": plaintext.base64EncodedString(),
        "frame": frame, "wire": String(data: try json(frame), encoding: .utf8)!])
}
for item in cases where item["envelope"] != nil && item["valid"] as? Bool == true {
    let envelope = item["envelope"] as! [String: Any]
    try append(name: "encrypted " + (item["name"] as! String), plaintext: json(envelope),
               source: envelope["sourceDeviceId"] as! String,
               target: envelope["targetDeviceId"] as! String, valid: true)
}
for name in ["duplicate payload key", "float v", "malformed UTF-8"] {
    let item = cases.first { $0["name"] as? String == name }!
    let plaintext = (item["rawEnvelopeBase64"] as? String).flatMap { Data(base64Encoded: $0) }
        ?? Data((item["rawEnvelope"] as! String).utf8)
    try append(name: "authenticated " + name, plaintext: plaintext,
               source: "test-mac", target: "test-pixel", valid: false)
}
for size in [4096, 4097] {
    var vector = vectors[0]
    let wire = vector["wire"] as! String
    precondition(wire.utf8.count < size)
    vector["name"] = "encrypted JSON exact \(size) bytes"
    vector["wire"] = wire + String(repeating: " ", count: size - wire.utf8.count)
    vector["wireBytes"] = size
    vector["valid"] = size == 4096
    vectors.append(vector)
}
let output: [String: Any] = ["schemaVersion": 1,
    "status": "FROZEN supplemental encrypted reconnect vectors; production tests pending",
    "generator": "docs/evidence/iteration-5/reconnect-vector-generator.swift",
    "scope": "Codec/framing evidence only. Each vector uses isolated replay state and now=issuedAt. Synthetic key and IVs must never enter production.",
    "vectors": vectors]
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    .write(to: destination)
print("Generated \(vectors.count) deterministic synthetic vectors")

import Foundation
import PlinkCore
import Testing

@Test
func reconnectFixtureCasesMatchMacWirePolicy() throws {
    try checkReconnectCases("cases.json")
}

@Test
func reconnectEscapedClassificationMatchesMacWirePolicy() throws {
    try checkReconnectCases("classification-cases.json")
}

private func checkReconnectCases(_ file: String) throws {
    let fixtureData = try Data(contentsOf: reconnectFixtureURL(file))
    let fixture = try #require(JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
    let cases = try #require(fixture["cases"] as? [[String: Any]])

    for fixtureCase in cases {
        let name = try #require(fixtureCase["name"] as? String)
        let valid = try #require(fixtureCase["valid"] as? Bool)
        let raw = try reconnectRawEnvelope(from: fixtureCase)

        if let expectedBytes = fixtureCase["rawEnvelopeBytes"] as? Int {
            #expect(raw.count == expectedBytes, "\(name): fixture byte count")
        }

        let accepted: Bool
        var rejection = ""
        do {
            let envelope = try PlinkEnvelope.decode(raw)
            try PayloadPolicy.validate(envelope)
            accepted = true
        } catch {
            accepted = false
            rejection = String(describing: error)
        }

        #expect(accepted == valid, "\(name): \(rejection)")
    }
}

@Test
func reconnectEncryptedVectorsMatchMacWirePolicy() throws {
    try checkReconnectEncryptedVectors("encrypted-vectors.json")
}

@Test
func reconnectOuterTimestampsMatchMacWirePolicy() throws {
    try checkReconnectEncryptedVectors("outer-timestamp-vectors.json")
}

private func checkReconnectEncryptedVectors(_ file: String) throws {
    let data = try Data(contentsOf: reconnectFixtureURL(file))
    let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for vector in try #require(fixture["vectors"] as? [[String: Any]]) {
        let name = try #require(vector["name"] as? String)
        let valid = try #require(vector["valid"] as? Bool)
        let wire = Data(try #require(vector["wire"] as? String).utf8)
        let frame = try PlinkJSON.decoder().decode(EncryptedPlinkFrame.self, from: wire)
        let keyBase64 = try #require(vector["sessionKeyBase64"] as? String)
        let key = try #require(Data(base64Encoded: keyBase64))
        let codec = EncryptedFrameCodec(sessionKey: key)
        var accepted = false
        var rejection = ""
        do {
            let envelope = try codec.open(frame, now: frame.issuedAt,
                expectedSourceDeviceId: frame.sourceDeviceId, expectedTargetDeviceId: frame.targetDeviceId,
                stateStore: InMemoryFrameStateStore(), wireBytes: wire.count)
            accepted = true
            if valid {
                let plaintextBase64 = try #require(vector["plaintextBase64"] as? String)
                let plaintext = try #require(Data(base64Encoded: plaintextBase64))
                #expect(envelope == (try PlinkEnvelope.decode(plaintext)), "\(name): plaintext")
            }
        } catch {
            accepted = false
            rejection = String(describing: error)
        }
        #expect(accepted == valid, "\(name): \(rejection)")
    }
}

private func reconnectRawEnvelope(from fixtureCase: [String: Any]) throws -> Data {
    if let base64 = fixtureCase["rawEnvelopeBase64"] as? String {
        return try #require(Data(base64Encoded: base64))
    }
    if let rawEnvelope = fixtureCase["rawEnvelope"] as? String {
        return Data(rawEnvelope.utf8)
    }
    return try JSONSerialization.data(
        withJSONObject: #require(fixtureCase["envelope"]),
        options: []
    )
}

private func reconnectFixtureURL(_ name: String = "cases.json") throws -> URL {
    let fixturePath = "shared/protocol/v1/reconnect/\(name)"
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        let candidate = directory.appendingPathComponent(fixturePath)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

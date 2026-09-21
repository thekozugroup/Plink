import Foundation
@testable import PlinkCore
import Testing

@Test func conditionalReconnectSharedWireVectors() throws {
    let data = try Data(contentsOf: reconnectFixtureURL("conditional-v2-vectors.json"))
    let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let context = try #require(fixture["syntheticContext"] as? [String: Any])
    let timestamp = try #require(context["now"] as? String)
    let now = try #require(ISO8601DateFormatter().date(from: timestamp))
    let key = Data(repeating: 7, count: 32)
    let lifetime = PairSessionLifetime(localID: "test-mac", peerID: "test-phone", sessionID: "fixture",
        sessionKey: key, stateStore: InMemoryFrameStateStore())
    let validator = ReconnectInitiator(lifetime: lifetime,
        listener: ReconnectListener(lifetime: lifetime) { _, _ in }, commitAuthority: ReconnectCommitAuthority())
    for vector in try #require(fixture["vectors"] as? [[String: Any]]) {
        let name = try #require(vector["id"] as? String)
        let raw = Data(try #require(vector["rawEnvelope"] as? String).utf8)
        let expected = try #require(vector["expectedV2WirePolicy"] as? Bool)
        let decoded = try? PlinkEnvelope.decode(raw)
        #expect((decoded != nil) == expected, "\(name): raw policy")
        if let decoded {
            let message = try ReconnectMessage(decoded)
            #expect(message.conditional)
            let expectedTranscript = try #require(vector["expectedTranscript"] as? Bool)
            let transcript = try #require(vector["context"] as? [String: Any])
            let phaseName = try #require(transcript["phase"] as? String)
            let phase = try #require(EventType(rawValue: "reconnect.\(phaseName)"))
            let source = try #require(transcript["source"] as? String)
            let target = try #require(transcript["target"] as? String)
            let m = try #require(transcript["m"] as? String)
            let p = try #require(transcript["p"] as? String)
            let r = try #require(transcript["r"] as? String)
            let mac = try IPv4Endpoint(#require(transcript["mac"] as? String))
            let phone = try IPv4Endpoint(#require(transcript["phone"] as? String))
            let codec = EncryptedFrameCodec(sessionKey: key)
            let frame = try codec.seal(decoded, sequence: 1, issuedAt: now)
            let wire = try PlinkJSON.encoder().encode(frame)
            var accepted = false
            do {
                let opened = try codec.open(frame, now: now,
                    expectedSourceDeviceId: source, expectedTargetDeviceId: target,
                    stateStore: InMemoryFrameStateStore(), wireBytes: wire.count, rawFrameData: wire)
                #expect(opened == decoded, "\(name): encrypted policy")
                // Match production's p learning on Challenge and r learning on Reverse.
                let learnsP = phase == .reconnectHello || phase == .reconnectChallenge
                let learnsR = phase == .reconnectHello || phase == .reconnectChallenge ||
                    phase == .reconnectProof || phase == .reconnectReverse
                try validator.require(ReconnectMessage(opened), type: phase, m: m,
                    p: learnsP ? nil : p, r: learnsR ? nil : r, mac: mac, phone: phone, conditional: true)
                accepted = true
            } catch {
                if expectedTranscript {
                    Issue.record(error, "\(name): expected transcript acceptance")
                } else if name == "wrong_direction" {
                    #expect(error as? PayloadPolicyError == .deviceMismatch)
                } else {
                    #expect(error as? ReconnectSessionError == .wrongPhase)
                }
            }
            #expect(accepted == expectedTranscript, "\(name): contextual result")
            // Hello/Proof/ReverseProof/Commit are not inbound Mac phases. For those vectors
            // this checks only the shared comparison, not Mac receive-state coverage.
            // Android must independently exercise Hello's actual socket/binding check.
        }
    }
}

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

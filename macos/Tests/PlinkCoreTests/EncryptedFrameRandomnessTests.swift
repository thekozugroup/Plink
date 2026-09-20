import Foundation
import Security
import Testing
@testable import PlinkCore

@Test func failedSecureRandomDoesNotReturnAnIV() {
    #expect(throws: SecureRandomError.unavailable(errSecNotAvailable)) {
        _ = try EncryptedFrameCodec.randomIV { _, _ in errSecNotAvailable }
    }
}

@Test func failedIVGenerationPreventsSealing() {
    let codec = EncryptedFrameCodec(sessionKey: Data("synthetic-test-key".utf8), randomIV: {
        throw SecureRandomError.unavailable(errSecNotAvailable)
    })
    #expect(throws: SecureRandomError.unavailable(errSecNotAvailable)) {
        _ = try codec.seal(randomnessTestEnvelope(), sequence: 1)
    }
}

@Test func explicitFixtureIVStillSupportsDeterministicVectors() throws {
    let codec = EncryptedFrameCodec(sessionKey: Data("synthetic-test-key".utf8), randomIV: {
        throw SecureRandomError.unavailable(errSecNotAvailable)
    })
    let envelope = randomnessTestEnvelope()
    let frame = try codec.seal(envelope, sequence: 1, iv: Data(repeating: 7, count: 12))
    #expect(try codec.open(frame) == envelope)
}

@Test func failedIVGenerationBurnsReservedSequence() async throws {
    let codec = EncryptedFrameCodec(sessionKey: Data("synthetic-test-key".utf8), randomIV: {
        throw SecureRandomError.unavailable(errSecNotAvailable)
    })
    let state = InMemoryFrameStateStore()
    let envelope = randomnessTestEnvelope()
    let client = SecureNetworkPlinkClient(host: "127.0.0.1", port: 1, codec: codec, stateStore: state)
    await #expect(throws: SecureRandomError.unavailable(errSecNotAvailable)) {
        try await client.send(envelope)
    }
    let scope = codec.stateScope(sourceDeviceId: envelope.sourceDeviceId,
                                targetDeviceId: envelope.targetDeviceId)
    #expect(try state.reserveSequence(scope: scope) == 2)
}

private func randomnessTestEnvelope() -> PlinkEnvelope {
    PlinkEnvelope(
        id: "randomness-test", type: .deviceStatus, sentAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceDeviceId: "synthetic-mac", targetDeviceId: "synthetic-pixel",
        payload: ["batteryLevel": .int(50)]
    )
}

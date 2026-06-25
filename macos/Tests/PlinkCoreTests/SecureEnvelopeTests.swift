import Foundation
import PlinkCore
import Testing

@Test
func secureEnvelopeRejectsTampering() throws {
    let codec = SecureEnvelopeCodec(sessionKey: Data("test-session-secret".utf8))
    let envelope = messageEnvelope()
    let sealed = try codec.seal(envelope, sequence: 4, nonce: "nonce", issuedAt: Date(timeIntervalSince1970: 1))
    var tampered = sealed
    tampered.envelope.sourceDeviceId = "attacker"

    #expect(throws: PayloadPolicyError.self) {
        _ = try codec.open(tampered)
    }
}

@Test
func secureEnvelopeOpensValidMessage() throws {
    let codec = SecureEnvelopeCodec(sessionKey: Data("test-session-secret".utf8))
    let envelope = messageEnvelope()
    let sealed = try codec.seal(envelope, sequence: 4, nonce: "nonce", issuedAt: Date(timeIntervalSince1970: 1))

    #expect(try codec.open(sealed) == envelope)
}

@Test
func unsafeWebURLFailsPolicy() throws {
    let envelope = PlinkEnvelope(
        id: "evt-web",
        type: .webOpen,
        sentAt: .now,
        sourceDeviceId: "pixel",
        targetDeviceId: "mac",
        payload: ["url": .string("javascript:alert(1)")]
    )

    #expect(throws: PayloadPolicyError.self) {
        try PayloadPolicy.validate(envelope)
    }
}

@Test
func redactionMasksSensitivePayloadValues() throws {
    let redacted = PayloadPolicy.redact(messageEnvelope())

    #expect(redacted.payload["preview"] == .string("[redacted]"))
    #expect(redacted.payload["sender"] == .string("Alex"))
}

private func messageEnvelope() -> PlinkEnvelope {
    PlinkEnvelope(
        id: "evt-1",
        type: .messageReceived,
        sentAt: Date(timeIntervalSince1970: 1),
        sourceDeviceId: "pixel",
        targetDeviceId: "mac",
        requiresAck: true,
        payload: [
            "sender": .string("Alex"),
            "preview": .string("Private"),
            "canReply": .bool(true)
        ]
    )
}

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

@Test
func encryptedFrameRoundTripsAndRejectsReplay() throws {
    let codec = EncryptedFrameCodec(sessionKey: Data("test-session-secret".utf8))
    let protector = ReplayProtector(maxClockSkew: 600)
    let issuedAt = Date(timeIntervalSince1970: 1_782_000_000)
    let frame = try codec.seal(
        messageEnvelope(),
        sequence: 1,
        nonce: "frame-nonce",
        issuedAt: issuedAt,
        iv: Data(repeating: 7, count: 12)
    )

    #expect(try codec.open(frame, replayProtector: protector, now: issuedAt.addingTimeInterval(1)) == messageEnvelope())
    #expect(throws: PayloadPolicyError.self) {
        _ = try codec.open(frame, replayProtector: protector, now: issuedAt.addingTimeInterval(2))
    }
}

@Test
func encryptedFrameRejectsTampering() throws {
    let codec = EncryptedFrameCodec(sessionKey: Data("test-session-secret".utf8))
    let frame = try codec.seal(messageEnvelope(), sequence: 1, nonce: "frame-nonce")
    var tampered = frame
    tampered.cipherText = String(tampered.cipherText.dropLast(2)) + "xx"

    #expect(throws: PayloadPolicyError.self) {
        _ = try codec.open(tampered)
    }
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
            "canReply": .bool(true),
            "packageName": .string("com.example.messages"),
            "notificationKey": .string("key"),
            "replyToken": .string("token")
        ]
    )
}

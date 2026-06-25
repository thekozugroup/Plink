import Foundation
import PlinkCore
import Testing

@Test
func envelopeRoundTrips() throws {
    let envelope = PlinkEnvelope(
        id: "evt-1",
        type: .messageReceived,
        sentAt: Date(timeIntervalSince1970: 1_782_000_000),
        sourceDeviceId: "pixel",
        targetDeviceId: "mac",
        requiresAck: true,
        payload: ["sender": "Alex", "canReply": "true"]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(envelope)
    let decoded = try decoder.decode(PlinkEnvelope.self, from: data)

    #expect(decoded == envelope)
}

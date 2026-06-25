import Foundation
import PlinkCore
import Testing

@Test
func messageEnvelopeCreatesReplyNotificationPlan() throws {
    let envelope = PlinkEnvelope(
        id: "evt-1",
        type: .messageReceived,
        sentAt: .now,
        sourceDeviceId: "pixel",
        targetDeviceId: "mac",
        requiresAck: true,
        payload: ["sender": .string("Alex"), "preview": .string("On my way"), "canReply": .bool(true)]
    )

    let plan = try #require(NotificationPlanner.plan(for: envelope))

    #expect(plan.categoryIdentifier == "plink.message")
    #expect(plan.allowsTextReply)
    #expect(plan.continuityResponseType == .messageReply)
}

@Test
func clipboardEnvelopeCreatesHandoffAction() throws {
    let envelope = PlinkEnvelope(
        id: "evt-2",
        type: .clipboardUpdated,
        sentAt: .now,
        sourceDeviceId: "pixel",
        targetDeviceId: "mac",
        payload: ["text": .string("https://plink.local")]
    )

    let action = try #require(HandoffPlanner.action(for: envelope))

    #expect(action == HandoffAction(kind: .clipboard("https://plink.local")))
}

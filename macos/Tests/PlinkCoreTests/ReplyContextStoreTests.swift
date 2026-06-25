import Foundation
import PlinkCore
import Testing

@Test
func replyContextStoreConsumesOnce() throws {
    let store = InMemoryReplyContextStore()
    let context = ReplyContext(
        sourceEnvelopeId: "evt",
        pairedDeviceId: "pixel",
        macDeviceId: "mac",
        packageName: "pkg",
        notificationKey: "key",
        conversationId: nil,
        replyToken: "token"
    )

    store.save(context, notificationId: "notification")

    #expect(store.take(notificationId: "notification") == context)
    #expect(store.take(notificationId: "notification") == nil)
}

import Foundation
import PlinkCore
import Testing

@Test
func messageBookkeepingEvictsOnlyOldestMessageAtCapacity() {
    var bookkeeping = MacNotificationBookkeeping()
    let now = Date(timeIntervalSince1970: 1_000)
    let callNotificationID = "plink.hfp.live-call.active"

    for index in 0..<MacNotificationBookkeeping.capacity {
        #expect(bookkeeping.store(
            notificationID: "message-\(index)",
            peerID: "pixel",
            notificationKey: "key-\(index)",
            context: replyContext(notificationKey: "key-\(index)"),
            now: now
        ).isEmpty)
    }

    let removed = bookkeeping.store(
        notificationID: "message-128",
        peerID: "pixel",
        notificationKey: "key-128",
        context: replyContext(notificationKey: "key-128"),
        now: now
    )

    #expect(bookkeeping.count == 128)
    #expect(removed == ["message-0"])
    #expect(!removed.contains(callNotificationID))
}

@Test
func messageBookkeepingRemovesIndexesOnReplyDismissalFailureAndExpiry() throws {
    var bookkeeping = MacNotificationBookkeeping()
    let now = Date(timeIntervalSince1970: 2_000)

    bookkeeping.store(
        notificationID: "reply",
        peerID: "pixel",
        notificationKey: "reply-key",
        context: replyContext(notificationKey: "reply-key"),
        now: now
    )
    #expect(bookkeeping.takeReply(notificationID: "reply", now: now)?.notificationKey == "reply-key")

    bookkeeping.store(
        notificationID: "dismissed",
        peerID: "pixel",
        notificationKey: "dismissed-key",
        context: replyContext(notificationKey: "dismissed-key"),
        now: now
    )
    let removedDismissed = bookkeeping.remove(notificationID: "dismissed")
    #expect(removedDismissed)

    bookkeeping.store(
        notificationID: "failed",
        peerID: "pixel",
        notificationKey: "failed-key",
        context: replyContext(notificationKey: "failed-key"),
        now: now
    )
    let removedFailed = bookkeeping.remove(notificationID: "failed")
    #expect(removedFailed)

    bookkeeping.store(
        notificationID: "expired",
        peerID: "pixel",
        notificationKey: "expired-key",
        context: replyContext(notificationKey: "expired-key"),
        now: now
    )
    #expect(bookkeeping.expire(now: now.addingTimeInterval(600)) == ["expired"])
    #expect(bookkeeping.count == 0)
}

@Test
func lateCleanupCannotRemoveReplacementOrSameKeyFromAnotherPeer() throws {
    var bookkeeping = MacNotificationBookkeeping()
    let now = Date(timeIntervalSince1970: 3_000)

    bookkeeping.store(
        notificationID: "peer-a-old",
        peerID: "pixel-a",
        notificationKey: "shared-key",
        context: replyContext(peerID: "pixel-a", notificationKey: "shared-key"),
        now: now
    )
    bookkeeping.store(
        notificationID: "peer-b",
        peerID: "pixel-b",
        notificationKey: "shared-key",
        context: replyContext(peerID: "pixel-b", notificationKey: "shared-key"),
        now: now
    )
    let replaced = bookkeeping.store(
        notificationID: "peer-a-new",
        peerID: "pixel-a",
        notificationKey: "shared-key",
        context: replyContext(peerID: "pixel-a", notificationKey: "shared-key"),
        now: now
    )

    #expect(replaced == ["peer-a-old"])
    let removedObsolete = bookkeeping.remove(notificationID: "peer-a-old")
    #expect(!removedObsolete)
    #expect(bookkeeping.takeReply(notificationID: "peer-a-new", now: now)?.pairedDeviceId == "pixel-a")
    #expect(bookkeeping.takeReply(notificationID: "peer-b", now: now)?.pairedDeviceId == "pixel-b")
}

@Test
func invalidLocalTextLeavesReplyContextAvailable() throws {
    var bookkeeping = MacNotificationBookkeeping()
    let now = Date(timeIntervalSince1970: 4_000)
    let context = replyContext(notificationKey: "key")
    bookkeeping.store(
        notificationID: "message",
        peerID: "pixel",
        notificationKey: "key",
        context: context,
        now: now
    )

    #expect(throws: ReplyRouterError.emptyReply) {
        try ReplyRouter.validateReplyText("\t\r\n")
    }
    try ReplyRouter.validateReplyText("\t valid \n")
    #expect(bookkeeping.takeReply(notificationID: "message", now: now) == context)
}

private func replyContext(peerID: String = "pixel", notificationKey: String) -> ReplyContext {
    ReplyContext(
        sourceEnvelopeId: "source-\(notificationKey)",
        pairedDeviceId: peerID,
        macDeviceId: "mac",
        packageName: "com.example.messages",
        notificationKey: notificationKey,
        conversationId: "thread",
        replyToken: "token-\(notificationKey)"
    )
}

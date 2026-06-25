import Foundation
import PlinkCore
import UserNotifications

final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let replyContextStore: ReplyContextStoring = UserDefaultsReplyContextStore()
    var onTextReply: ((ReplyContext, String) -> Void)?
    var onCallAction: ((String) -> Void)?
    var onAuthorizationChanged: ((Bool, Error?) -> Void)?
    var onDeliveryError: ((String, Error) -> Void)?

    func configure() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: "message.reply",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let decline = UNNotificationAction(identifier: "call.decline", title: "Decline", options: [])
        let callCategory = UNNotificationCategory(identifier: "plink.call", actions: [decline], intentIdentifiers: [])
        let messageCategory = UNNotificationCategory(identifier: "plink.message", actions: [reply], intentIdentifiers: [])
        let readOnlyMessageCategory = UNNotificationCategory(identifier: "plink.message.readonly", actions: [], intentIdentifiers: [])
        center.setNotificationCategories([callCategory, messageCategory, readOnlyMessageCategory])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.onAuthorizationChanged?(granted, error)
        }
    }

    func showCall(caller: String, handle: String) {
        show(envelope: PlinkEnvelope(
            id: "call_\(UUID().uuidString)",
            type: .callRinging,
            sentAt: .now,
            sourceDeviceId: "pixel-demo",
            targetDeviceId: "mac-demo",
            requiresAck: true,
            payload: [
                "callerName": .string(caller),
                "callerHandle": .string(handle),
                "canDecline": .bool(true)
            ]
        ))
    }

    func showMessage(sender: String, preview: String) {
        show(envelope: PlinkEnvelope(
            id: "msg_\(UUID().uuidString)",
            type: .messageReceived,
            sentAt: .now,
            sourceDeviceId: "pixel-demo",
            targetDeviceId: "mac-demo",
            requiresAck: true,
            payload: [
                "sender": .string(sender),
                "preview": .string(preview),
                "canReply": .bool(true),
                "packageName": .string("com.google.android.apps.messaging"),
                "notificationKey": .string("demo-message"),
                "conversationId": .string("demo-thread"),
                "replyToken": .string(UUID().uuidString)
            ]
        ))
    }

    func show(envelope: PlinkEnvelope) {
        guard let plan = NotificationPlanner.plan(for: envelope) else { return }
        show(
            plan: plan,
            id: "\(plan.categoryIdentifier)-\(envelope.id)",
            replyContext: ReplyRouter.context(from: envelope)
        )
    }

    func show(
        plan: NativeNotificationPlan,
        id: String = "\(UUID().uuidString)",
        replyContext: ReplyContext? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.subtitle = plan.subtitle
        content.body = plan.body
        content.categoryIdentifier = plan.categoryIdentifier == "plink.message" && !plan.allowsTextReply
            ? "plink.message.readonly"
            : plan.categoryIdentifier
        submit(content: content, id: id, replyContext: replyContext)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.actionIdentifier == "call.decline" {
            onCallAction?(response.notification.request.identifier)
            return
        }
        guard let response = response as? UNTextInputNotificationResponse else { return }
        guard let context = takeReplyContext(for: response.notification.request.identifier) else { return }
        onTextReply?(context, response.userText)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func submit(content: UNMutableNotificationContent, id: String, replyContext: ReplyContext?) {
        if let replyContext {
            store(replyContext, for: id)
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error {
                self?.onDeliveryError?(id, error)
                self?.takeReplyContext(for: id)
            }
        }
    }

    private func store(_ context: ReplyContext, for id: String) {
        try? replyContextStore.save(context, notificationId: id)
    }

    @discardableResult
    private func takeReplyContext(for id: String) -> ReplyContext? {
        try? replyContextStore.take(notificationId: id)
    }
}

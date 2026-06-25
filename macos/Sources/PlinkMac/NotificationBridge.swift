import Foundation
import PlinkCore
import UserNotifications

final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onTextReply: ((String) -> Void)?

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
        center.setNotificationCategories([callCategory, messageCategory])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func showCall(caller: String, handle: String) {
        show(
            plan: NativeNotificationPlan(
                categoryIdentifier: "plink.call",
                title: "Incoming call",
                subtitle: caller,
                body: handle
            )
        )
    }

    func showMessage(sender: String, preview: String) {
        show(
            plan: NativeNotificationPlan(
                categoryIdentifier: "plink.message",
                title: sender,
                body: preview,
                allowsTextReply: true,
                continuityResponseType: .messageReply
            )
        )
    }

    func show(plan: NativeNotificationPlan) {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.subtitle = plan.subtitle
        content.body = plan.body
        content.categoryIdentifier = plan.categoryIdentifier
        submit(content: content, id: "\(plan.categoryIdentifier)-\(UUID().uuidString)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let response = response as? UNTextInputNotificationResponse {
            onTextReply?(response.userText)
        }
    }

    private func submit(content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request)
    }
}

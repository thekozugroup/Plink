import Foundation
import UserNotifications

final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

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
        let content = UNMutableNotificationContent()
        content.title = "Incoming call"
        content.subtitle = caller
        content.body = handle
        content.categoryIdentifier = "plink.call"
        submit(content: content, id: "call-\(UUID().uuidString)")
    }

    func showMessage(sender: String, preview: String) {
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = preview
        content.categoryIdentifier = "plink.message"
        submit(content: content, id: "message-\(UUID().uuidString)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let response = response as? UNTextInputNotificationResponse {
            print("Plink reply queued: \(response.userText)")
        }
    }

    private func submit(content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request)
    }
}

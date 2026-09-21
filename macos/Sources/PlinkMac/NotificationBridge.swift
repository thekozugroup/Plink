import Foundation
import PlinkCore
import UserNotifications

@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var messages = MacNotificationBookkeeping()
    private var callContext: MacCallContext?
    private var callNotificationID: String?
    private var callNumber: String?
    private var authorizationRefresh = UUID()
    var onTextReply: ((ReplyContext, String) -> Void)?
    var onCallAction: ((MacCallAction, MacCallContext) -> Void)?
    var onAuthorizationChanged: ((Bool, Error?) -> Void)?
    var onDeliveryError: ((String, Error) -> Void)?
    var onStaleAction: (() -> Void)?
    var onInvalidReply: (() -> Void)?

    func configure() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "message.reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let answer = UNNotificationAction(identifier: "call.answer", title: "Answer on Mac", options: [.authenticationRequired])
        let decline = UNNotificationAction(identifier: "call.decline", title: "Decline", options: [.authenticationRequired])
        let end = UNNotificationAction(identifier: "call.hangUp", title: "End Call", options: [.authenticationRequired, .destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "plink.call.ringing", actions: [answer, decline], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plink.call.active", actions: [end], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plink.call.readonly", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plink.message", actions: [reply], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: "plink.message.readonly", actions: [], intentIdentifiers: [])
        ])
        // Live Android reply capabilities and call identities do not survive restart.
        clearContexts()
        // Only startup clears all OS notifications. Message eviction must preserve live calls.
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        refreshAuthorization()
    }

    func refreshAuthorization() {
        let refresh = UUID()
        authorizationRefresh = refresh
        Task {
            let settings = await center.notificationSettings()
            guard authorizationRefresh == refresh else { return }
            onAuthorizationChanged?(settings.authorizationStatus == .authorized, nil)
        }
    }

    /// Called only from an explicit user control, never automatically on launch.
    func requestAuthorization() {
        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                refreshAuthorization()
            }
            catch { onAuthorizationChanged?(false, error) }
        }
    }

    func clearContexts() {
        removeMessages(messages.removeAll())
    }

    func shutdown() {
        clearContexts()
        let ids = [callNotificationID, "plink.call.mirrored"].compactMap { $0 }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        callContext = nil; callNotificationID = nil; callNumber = nil
    }

    func expireContexts() {
        removeMessages(messages.expire())
    }

    func updateCall(_ call: MacCallSession) {
        guard call.stateIsCertain, let context = call.context, [.ringing, .active].contains(call.phase), !call.hasWaitingCall else {
            if let id = callNotificationID {
                center.removeDeliveredNotifications(withIdentifiers: [id])
                center.removePendingNotificationRequests(withIdentifiers: [id])
            }
            callContext = nil; callNotificationID = nil; callNumber = nil
            return
        }
        let id = "plink.hfp.\(context.callID).\(call.phase.rawValue)"
        center.removeDeliveredNotifications(withIdentifiers: ["plink.call.mirrored"])
        center.removePendingNotificationRequests(withIdentifiers: ["plink.call.mirrored"])
        guard callNotificationID != id || callNumber != call.number else { return }
        if let old = callNotificationID {
            center.removeDeliveredNotifications(withIdentifiers: [old])
            center.removePendingNotificationRequests(withIdentifiers: [old])
        }
        callContext = context; callNotificationID = id
        callNumber = call.number
        let content = UNMutableNotificationContent()
        content.title = call.phase == .ringing ? "Incoming call" : "Call active"
        content.body = call.number ?? "Unknown caller"
        content.categoryIdentifier = call.phase == .ringing ? "plink.call.ringing" : "plink.call.active"
        if call.phase == .ringing { content.sound = .default }
        submit(content, id: id)
    }

    func show(envelope: PlinkEnvelope) {
        if envelope.type == .callEnded {
            center.removeDeliveredNotifications(withIdentifiers: ["plink.call.mirrored"])
            center.removePendingNotificationRequests(withIdentifiers: ["plink.call.mirrored"])
            return // Only HFP identities may drive controls.
        }
        if envelope.type == .callRinging {
            if callContext != nil { return }
            let content = UNMutableNotificationContent()
            content.title = "Call notification from phone"
            content.body = envelope.payload["callerName"]?.stringValue ?? "Check your phone"
            content.categoryIdentifier = "plink.call.readonly"
            submit(content, id: "plink.call.mirrored")
            return
        }
        guard let plan = NotificationPlanner.plan(for: envelope) else { return }
        let id = "\(plan.categoryIdentifier)-\(envelope.id)"
        let context = ReplyRouter.context(from: envelope)
        if envelope.type == .messageReceived,
           let key = envelope.payload["notificationKey"]?.stringValue {
            let obsolete = envelope.payload["removed"]?.boolValue == true
                ? messages.remove(notificationKey: key, peerID: envelope.sourceDeviceId)
                : messages.store(
                    notificationID: id,
                    peerID: envelope.sourceDeviceId,
                    notificationKey: key,
                    context: context
                )
            removeMessages(obsolete)
        }
        if envelope.payload["removed"]?.boolValue == true { return }
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.subtitle = plan.subtitle
        content.body = plan.body
        content.categoryIdentifier = plan.categoryIdentifier == "plink.message" && context == nil ? "plink.message.readonly" : plan.categoryIdentifier
        submit(content, id: id)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            if action.hasPrefix("call."), let callAction = MacCallAction(rawValue: String(action.dropFirst(5))) {
                guard id == self.callNotificationID, let context = self.callContext else { self.onStaleAction?(); return }
                self.onCallAction?(callAction, context)
                return
            }
            if action == UNNotificationDismissActionIdentifier { _ = self.messages.remove(notificationID: id); return }
            guard action == "message.reply", let text else { return }
            do { try ReplyRouter.validateReplyText(text) }
            catch { self.onInvalidReply?(); return }
            guard let context = self.messages.takeReply(notificationID: id) else { self.onStaleAction?(); return }
            self.center.removeDeliveredNotifications(withIdentifiers: [id])
            self.onTextReply?(context, text)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    private func submit(_ content: UNMutableNotificationContent, id: String) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                _ = self?.messages.remove(notificationID: id)
                self?.onDeliveryError?(id, error)
            }
        }
    }

    private func removeMessages(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

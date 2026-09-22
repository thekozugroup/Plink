import Foundation
import PlinkCore
import UserNotifications

@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    private lazy var center = UNUserNotificationCenter.current()
    private let submitNotification: ((UNNotificationRequest) -> Void)?
    private let removeNotifications: (([String]) -> Void)?
    private let addNotification: ((UNNotificationRequest, @escaping @MainActor (Error?) -> Void) -> Void)?
    // Late delivery completions may only affect the current submission for this ID.
    private var submissions: [String: UUID] = [:]
    private var messages = MacNotificationBookkeeping()
    private var callContext: MacCallContext?
    private var callNotificationID: String?
    private var callNumber: String?
    private struct MirroredCallIdentity: Equatable {
        let peerID: String
        let notificationKey: String

        init?(_ envelope: PlinkEnvelope) {
            guard let key = envelope.payload["notificationKey"]?.stringValue, !key.isEmpty else { return nil }
            peerID = envelope.sourceDeviceId
            notificationKey = key
        }
    }
    private var mirroredCallIdentity: MirroredCallIdentity?
    private var authorizationRefresh = UUID()
    var onTextReply: ((ReplyContext, String) -> Void)?
    var onCallAction: ((MacCallAction, MacCallContext) -> Void)?
    var onAuthorizationChanged: ((Bool, Error?) -> Void)?
    var onDeliveryError: ((String, Error) -> Void)?
    var onStaleAction: (() -> Void)?
    var onInvalidReply: (() -> Void)?

    init(
        submitNotification: ((UNNotificationRequest) -> Void)? = nil,
        removeNotifications: (([String]) -> Void)? = nil,
        addNotification: ((UNNotificationRequest, @escaping @MainActor (Error?) -> Void) -> Void)? = nil
    ) {
        self.submitNotification = submitNotification
        self.removeNotifications = removeNotifications
        self.addNotification = addNotification
        super.init()
    }

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
        submissions.removeAll()
        removeMessages(messages.removeAll())
        removeDeliveredAndPending(["plink.call.mirrored"])
        mirroredCallIdentity = nil
    }

    func shutdown() {
        clearContexts()
        let ids = [callNotificationID, "plink.call.mirrored"].compactMap { $0 }
        removeDeliveredAndPending(ids)
        callContext = nil; callNotificationID = nil; callNumber = nil
        mirroredCallIdentity = nil
    }

    func expireContexts() {
        removeMessages(messages.expire())
    }

    func updateCall(_ call: MacCallSession, presentNotification: Bool = true) {
        if !presentNotification, let context = call.context {
            removeDeliveredAndPending([callNotificationID, "plink.call.mirrored"].compactMap { $0 })
            mirroredCallIdentity = nil
            // Keep authoritative HFP ownership during pending/uncertain phases too, so
            // delayed mirrored events cannot create a second presentation over the panel.
            callContext = context; callNotificationID = nil; callNumber = call.number
            return
        }
        guard call.stateIsCertain, let context = call.context, [.ringing, .active].contains(call.phase), !call.hasWaitingCall else {
            if let id = callNotificationID {
                removeDeliveredAndPending([id])
            }
            callContext = nil; callNotificationID = nil; callNumber = nil
            return
        }
        let id = "plink.hfp.\(context.callID).\(call.phase.rawValue)"
        removeDeliveredAndPending(["plink.call.mirrored"])
        mirroredCallIdentity = nil
        guard callNotificationID != id || callNumber != call.number else { return }
        if let old = callNotificationID {
            removeDeliveredAndPending([old])
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

    func show(envelope: PlinkEnvelope, pairedPhoneName: String? = nil) {
        if envelope.type == .callEnded {
            guard let identity = MirroredCallIdentity(envelope), identity == mirroredCallIdentity else { return }
            removeDeliveredAndPending(["plink.call.mirrored"])
            mirroredCallIdentity = nil
            return // Only HFP identities may drive controls.
        }
        if envelope.type == .callRinging {
            if callContext != nil { return }
            mirroredCallIdentity = MirroredCallIdentity(envelope)
            let content = UNMutableNotificationContent()
            content.title = "Call notification from phone"
            content.body = envelope.payload["callerName"]?.stringValue ?? "Check your phone"
            content.categoryIdentifier = "plink.call.readonly"
            submitFromPhone(content, id: "plink.call.mirrored", envelope: envelope, phoneName: pairedPhoneName)
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
        if envelope.type == .messageReceived {
            submitFromPhone(content, id: id, envelope: envelope, phoneName: pairedPhoneName)
        } else {
            submit(content, id: id)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await handleResponse(id: id, action: action, text: text)
    }

    // Same action path for native responses and held-delivery regression tests.
    func handleResponse(id: String, action: String, text: String?) {
        if action.hasPrefix("call."), let callAction = MacCallAction(rawValue: String(action.dropFirst(5))) {
            guard id == self.callNotificationID, let context = self.callContext else { self.onStaleAction?(); return }
            self.onCallAction?(callAction, context)
            return
        }
        if action == UNNotificationDismissActionIdentifier {
            self.removeDeliveredAndPending([id])
            _ = self.messages.remove(notificationID: id)
            return
        }
        guard action == "message.reply", let text else { return }
        do { try ReplyRouter.validateReplyText(text) }
        catch { self.onInvalidReply?(); return }
        guard let context = self.messages.takeReply(notificationID: id) else { self.onStaleAction?(); return }
        self.removeDeliveredAndPending([id])
        self.onTextReply?(context, text)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    private func submitFromPhone(_ content: UNMutableNotificationContent, id: String,
                                   envelope: PlinkEnvelope, phoneName: String?) {
        content.subtitle = NotificationArtwork.subtitle(appName: envelope.payload["sourceAppName"]?.stringValue,
                                                       phoneName: phoneName)
        submit(content, id: id)
    }

    private func submit(_ content: UNMutableNotificationContent, id: String) {
        submissions.removeValue(forKey: id)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        if let submitNotification { submitNotification(request); return }
        let token = UUID()
        submissions[id] = token
        let completion: @MainActor (Error?) -> Void = { [weak self] error in
            guard let self, self.submissions[id] == token else { return }
            self.submissions.removeValue(forKey: id)
            guard let error else { return }
            _ = self.messages.remove(notificationID: id)
            self.onDeliveryError?(id, error)
        }
        if let addNotification { addNotification(request, completion); return }
        center.add(request) { error in
            Task { @MainActor in completion(error) }
        }
    }

    private func removeMessages(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        removeDeliveredAndPending(ids)
    }

    private func removeDeliveredAndPending(_ ids: [String]) {
        for id in ids { submissions.removeValue(forKey: id) }
        if let removeNotifications { removeNotifications(ids); return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

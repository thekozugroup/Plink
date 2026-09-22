import Foundation
import OSLog
import PlinkCore
import UserNotifications

@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    private let callLog = Logger(subsystem: "com.thekozugroup.plink.mac", category: "bluetooth-calling")
    private lazy var center = UNUserNotificationCenter.current()
    private let submitNotification: ((UNNotificationRequest) -> Void)?
    private let removeNotifications: (([String]) -> Void)?
    private let addNotification: ((UNNotificationRequest, @escaping @MainActor (Error?) -> Void) -> Void)?
    private let artwork: NotificationArtwork.Staging
    // Late delivery completions may only affect the current submission for this ID.
    private var submissions: [String: UUID] = [:]
    private var messages = MacNotificationBookkeeping()
    private var callContext: MacCallContext?
    private var callNotificationID: String?
    private var callNumber: String?
    private var callAudioUnavailableReason: String?
    private var currentCall = MacCallSession()
    private var callPresentationAllowed = true
    private var callActionConsumed = false
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
    private var mirroredCallNotificationID: String?
    private var authorizationRefresh = UUID()
    var onTextReply: ((ReplyContext, String) -> Void)?
    var onCallAction: ((MacCallAction, MacCallContext) -> Void)?
    var callActionsAllowed: (() -> Bool)?
    var onAuthorizationChanged: ((Bool, Error?) -> Void)?
    var onDeliveryError: ((String, Error) -> Void)?
    var onStaleAction: (() -> Void)?
    var onInvalidReply: (() -> Void)?

    init(
        submitNotification: ((UNNotificationRequest) -> Void)? = nil,
        removeNotifications: (([String]) -> Void)? = nil,
        addNotification: ((UNNotificationRequest, @escaping @MainActor (Error?) -> Void) -> Void)? = nil,
        artwork: NotificationArtwork.Staging? = nil
    ) {
        self.submitNotification = submitNotification
        self.removeNotifications = removeNotifications
        self.addNotification = addNotification
        self.artwork = artwork ?? NotificationArtwork.Staging()
        super.init()
    }

    func configure() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "message.reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        center.setNotificationCategories(Self.callCategories.union([
            UNNotificationCategory(identifier: "plink.call.readonly", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plink.message", actions: [reply], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: "plink.message.readonly", actions: [], intentIdentifiers: [])
        ]))
        // Live Android reply capabilities and call identities do not survive restart.
        clearContexts()
        // Only startup clears all OS notifications. Message eviction must preserve live calls.
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        refreshAuthorization()
    }

    static var callCategories: Set<UNNotificationCategory> {
        let answer = UNNotificationAction(identifier: "call.answer", title: "Answer", options: [.authenticationRequired])
        let decline = UNNotificationAction(identifier: "call.decline", title: "Decline", options: [.authenticationRequired])
        let end = UNNotificationAction(identifier: "call.hangUp", title: "End Call", options: [.authenticationRequired, .destructive])
        return [
            UNNotificationCategory(identifier: "plink.call.ringing", actions: [answer, decline], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: "plink.call.active", actions: [end], intentIdentifiers: [], options: [.customDismissAction])
        ]
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
        removeMirroredCall()
    }

    func shutdown() {
        callPresentationAllowed = false
        currentCall = MacCallSession()
        clearContexts()
        let ids = [callNotificationID].compactMap { $0 }
        removeDeliveredAndPending(ids)
        callContext = nil; callNotificationID = nil; callNumber = nil
        mirroredCallIdentity = nil
    }

    func expireContexts() {
        removeMessages(messages.expire())
    }

    func updateCall(_ call: MacCallSession, presentNotification: Bool = true,
                    hfpControlsAvailable: Bool = true,
                    audioUnavailableReason: String? = nil) {
        let unchanged = callContext == call.context && currentCall.phase == call.phase &&
            callNumber == call.number && callAudioUnavailableReason == audioUnavailableReason
        callAudioUnavailableReason = audioUnavailableReason
        currentCall = call
        callContext = call.context
        callPresentationAllowed = presentNotification
        // HFP retains authority during pending/uncertain phases, even without a banner.
        if callContext != nil || !presentNotification {
            removeMirroredCall()
        }
        guard presentNotification, hfpControlsAvailable, call.stateIsCertain, let context = call.context,
              [.ringing, .active].contains(call.phase), !call.hasWaitingCall else {
            if let id = callNotificationID { removeDeliveredAndPending([id]) }
            callNotificationID = nil; callNumber = call.number
            return
        }
        guard callNotificationID == nil || !unchanged else { return }
        if let old = callNotificationID { removeDeliveredAndPending([old]) }
        // A new presentation after lock/unlock must reject responses to its predecessor,
        // even when the underlying HFP context and phase have not changed.
        let id = "plink.hfp.\(context.callID).\(call.phase.rawValue).\(UUID().uuidString)"
        callNotificationID = id; callNumber = call.number; callActionConsumed = false
        let content = UNMutableNotificationContent()
        content.title = call.phase == .ringing ? "Incoming call" : "Call active"
        content.body = call.number ?? "Unknown caller"
        content.subtitle = audioUnavailableReason ?? ""
        content.categoryIdentifier = call.phase == .ringing ? "plink.call.ringing" : "plink.call.active"
        if call.phase == .ringing { content.sound = .default }
        submit(content, id: id)
    }

    func show(envelope: PlinkEnvelope, pairedPhoneName: String? = nil) {
        if envelope.type == .messageReceived {
            callLog.notice("calls.notification.received.messageReceived")
        }
        if envelope.type == .callEnded {
            guard let identity = MirroredCallIdentity(envelope), identity == mirroredCallIdentity else { return }
            removeMirroredCall()
            return // Only HFP identities may drive controls.
        }
        if envelope.type == .callRinging {
            callLog.notice("calls.notification.received.callRinging")
            if !callPresentationAllowed {
                callLog.notice("calls.notification.callRinging.skipped.privacy")
                return
            }
            if callContext != nil {
                callLog.notice("calls.notification.callRinging.skipped.hfp_context")
                return
            }
            removeMirroredCall()
            let id = "plink.call.mirrored.\(UUID().uuidString)"
            mirroredCallNotificationID = id
            mirroredCallIdentity = MirroredCallIdentity(envelope)
            let content = UNMutableNotificationContent()
            content.title = "Call notification from phone"
            content.body = envelope.payload["callerName"]?.stringValue ?? "Check your phone"
            content.categoryIdentifier = "plink.call.readonly"
            callLog.notice("calls.notification.callRinging.submitting.readonly")
            submitFromPhone(content, id: id, envelope: envelope, phoneName: pairedPhoneName)
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
            guard [.answer, .decline, .hangUp].contains(callAction),
                  callPresentationAllowed, !callActionConsumed, id == callNotificationID,
                  let context = callContext, currentCall.permits(callAction, context: context),
                  callActionsAllowed?() ?? true else { onStaleAction?(); return }
            callActionConsumed = true
            removeDeliveredAndPending([id])
            onCallAction?(callAction, context)
            return
        }
        if action == UNNotificationDismissActionIdentifier {
            if id == callNotificationID { callActionConsumed = true }
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
        let stage = envelope.type == .messageReceived
            ? artwork.stage(envelope.payload["sourceAppIconPng"]?.stringValue) : nil
        if envelope.type == .messageReceived {
            if stage != nil {
                callLog.notice("calls.notification.messageReceived.attachment.staged")
            } else {
                callLog.notice("calls.notification.messageReceived.attachment.none")
            }
        }
        if let stage { content.attachments = [stage.attachment] }
        submit(content, id: id, stage: stage)
    }

    private func submit(_ content: UNMutableNotificationContent, id: String,
                        stage: NotificationArtwork.Stage? = nil) {
        submissions.removeValue(forKey: id)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        if let submitNotification {
            submitNotification(request)
            if let stage { artwork.finish(stage) }
            return
        }
        let token = UUID()
        submissions[id] = token
        let completion: @MainActor (Error?) -> Void = { [weak self, artwork] error in
            // Cleanup belongs to this handoff, even if its message owner was revoked.
            // Never use attachment.url: macOS may have moved it into daemon storage.
            if let stage { artwork.finish(stage) }
            guard let self else { return }
            guard self.submissions[id] == token else {
                // An add can finish after privacy/ownership cleanup. HFP presentation IDs
                // are unique, so removing this retired request cannot remove its replacement.
                if id.hasPrefix("plink.hfp."),
                   self.callNotificationID != id || self.callActionConsumed || !self.callPresentationAllowed {
                    self.removeDeliveredAndPending([id])
                } else if id.hasPrefix("plink.call.mirrored."), self.mirroredCallNotificationID != id {
                    self.removeDeliveredAndPending([id])
                }
                return
            }
            self.submissions.removeValue(forKey: id)
            guard let error else { return }
            if stage != nil, let plain = content.mutableCopy() as? UNMutableNotificationContent {
                plain.attachments = []
                self.submit(plain, id: id) // One fallback; its own generation guards completion.
                return
            }
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

    private func removeMirroredCall() {
        if let id = mirroredCallNotificationID { removeDeliveredAndPending([id]) }
    }

    private func removeDeliveredAndPending(_ ids: [String]) {
        for id in ids {
            submissions.removeValue(forKey: id)
            if mirroredCallNotificationID == id {
                mirroredCallNotificationID = nil
                mirroredCallIdentity = nil
            }
        }
        if let removeNotifications { removeNotifications(ids); return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

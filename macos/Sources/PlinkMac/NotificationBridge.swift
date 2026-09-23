import Foundation
import CryptoKit
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
    // Late delivery completions may only affect the current submission for this ID.
    private var submissions: [String: UUID] = [:]
    private var messages = MacNotificationBookkeeping()
    private let registerCategories: ((Set<UNNotificationCategory>) -> Void)?
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var actionSession: NotificationActionSession?
    private struct ActionPresentation {
        let offer: NotificationActionOffer
        let category: UNNotificationCategory
        var consumed: Set<Int> = []
    }
    private var actionPresentations: [String: ActionPresentation] = [:]
    var onNotificationAction: ((PlinkEnvelope, UUID) -> Void)?
    var notificationActionsAllowed: ((UUID) -> Bool)?
    var onActionInfo: ((String) -> Void)?
    var onOpenNotification: (() -> Void)?
    private var latestActionCommandID: String?
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
    private var dismissedMirroredIdentity: MirroredCallIdentity?
    private var pendingMirroredCall: (id: String, peerID: String, identity: MirroredCallIdentity?, content: UNMutableNotificationContent)?
    private var selectedCallPeerID: String?
    private var readyHFPPeerID: String?
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
        registerCategories: ((Set<UNNotificationCategory>) -> Void)? = nil,
        now: @escaping () -> Date = { .now },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, fire in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                fire()
            }
        }
    ) {
        self.submitNotification = submitNotification
        self.removeNotifications = removeNotifications
        self.addNotification = addNotification
        self.registerCategories = registerCategories
        self.now = now
        self.schedule = schedule
        super.init()
    }

    func configure() {
        center.delegate = self
        publishCategories()
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
        endWaitingAction()
        actionSession = nil
        removeMessages(messages.removeAll())
        removeMirroredCall()
        dismissedMirroredIdentity = nil
        selectedCallPeerID = nil
        readyHFPPeerID = nil
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
        let expired = actionPresentations.filter { $0.value.offer.expires <= now() }.map(\.key)
        for id in expired { _ = messages.remove(notificationID: id) }
        removeMessages(expired + messages.expire(now: now()))
        let timedOut = actionSession?.expire(now: now()) ?? []
        if timedOut.contains(where: { $0.envelope.id == latestActionCommandID && $0.presentationID != nil }) {
            endWaitingAction()
        }
    }

    func updateCall(_ call: MacCallSession, presentNotification: Bool = true,
                     hfpControlsAvailable: Bool = true,
                     audioUnavailableReason: String? = nil,
                     selectedPeerID: String? = nil) {
        let previousContext = callContext
        let previousPhase = currentCall.phase
        let previousPhoneID = currentCall.phoneID
        let previousPeerID = selectedCallPeerID
        let unchanged = callContext == call.context && currentCall.phase == call.phase &&
            callNumber == call.number && callAudioUnavailableReason == audioUnavailableReason
        callAudioUnavailableReason = audioUnavailableReason
        currentCall = call
        callContext = call.context
        callPresentationAllowed = presentNotification
        selectedCallPeerID = selectedPeerID
        readyHFPPeerID = hfpControlsAvailable && call.phoneID != nil && call.context == nil ? selectedPeerID : nil
        // HFP retains authority during pending/uncertain phases, even without a banner.
        if callContext != nil || !presentNotification || previousPhoneID != call.phoneID ||
            previousPeerID != selectedPeerID ||
            (previousContext != nil && call.context == nil) {
            removeMirroredCall()
            dismissedMirroredIdentity = nil
        }
        guard presentNotification, hfpControlsAvailable, call.stateIsCertain, let context = call.context,
              [.ringing, .active].contains(call.phase), !call.hasWaitingCall else {
            if let id = callNotificationID { removeDeliveredAndPending([id]) }
            callNotificationID = nil; callNumber = call.number
            return
        }
        if let id = callNotificationID, previousContext == context, previousPhase == call.phase {
            guard !unchanged, !callActionConsumed else { return }
            callNumber = call.number
            let content = callContent(call, audioUnavailableReason: audioUnavailableReason)
            content.sound = nil
            submit(content, id: id)
            return
        }
        if let old = callNotificationID { removeDeliveredAndPending([old]) }
        // A new presentation after lock/unlock must reject responses to its predecessor,
        // even when the underlying HFP context and phase have not changed.
        let id = "plink.hfp.\(context.callID).\(call.phase.rawValue).\(UUID().uuidString)"
        callNotificationID = id; callNumber = call.number; callActionConsumed = false
        let content = callContent(call, audioUnavailableReason: audioUnavailableReason)
        if call.phase == .ringing { content.sound = .default }
        submit(content, id: id)
    }

    private func callContent(_ call: MacCallSession, audioUnavailableReason: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = call.phase == .ringing ? "Incoming call" : "Call active"
        content.body = call.number ?? "Unknown caller"
        content.subtitle = audioUnavailableReason ?? ""
        content.categoryIdentifier = call.phase == .ringing ? "plink.call.ringing" : "plink.call.active"
        return content
    }

    func show(envelope: PlinkEnvelope, pairedPhoneName: String? = nil) {
        if envelope.type == .messageReceived {
            callLog.notice("calls.notification.received.messageReceived")
        }
        if envelope.type == .callEnded {
            guard let identity = MirroredCallIdentity(envelope),
                  identity == mirroredCallIdentity || identity == pendingMirroredCall?.identity ||
                  identity == dismissedMirroredIdentity else { return }
            removeMirroredCall()
            dismissedMirroredIdentity = nil
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
            let identity = MirroredCallIdentity(envelope)
            if identity != nil && identity == dismissedMirroredIdentity { return }
            if identity != nil && (identity == mirroredCallIdentity || identity == pendingMirroredCall?.identity),
               mirroredCallNotificationID != nil || pendingMirroredCall != nil { return }
            removeMirroredCall()
            let id = "plink.call.mirrored.\(UUID().uuidString)"
            let content = UNMutableNotificationContent()
            content.title = "Call notification from phone"
            content.body = envelope.payload["callerName"]?.stringValue ?? "Check your phone"
            content.categoryIdentifier = "plink.call.readonly"
            content.subtitle = NotificationArtwork.subtitle(appName: envelope.payload["sourceAppName"]?.stringValue,
                                                           phoneName: pairedPhoneName)
            if readyHFPPeerID == envelope.sourceDeviceId {
                pendingMirroredCall = (id, envelope.sourceDeviceId, identity, content)
                schedule(0.3) { [weak self] in
                    guard let self, let pending = self.pendingMirroredCall, pending.id == id,
                          self.selectedCallPeerID == pending.peerID,
                          self.callPresentationAllowed, self.callContext == nil else { return }
                    self.pendingMirroredCall = nil
                    self.mirroredCallNotificationID = id
                    self.mirroredCallIdentity = pending.identity
                    self.callLog.notice("calls.notification.callRinging.submitting.readonly")
                    self.submit(pending.content, id: id)
                }
            } else {
                mirroredCallNotificationID = id
                mirroredCallIdentity = identity
                callLog.notice("calls.notification.callRinging.submitting.readonly")
                submit(content, id: id)
            }
            return
        }
        guard let plan = NotificationPlanner.plan(for: envelope) else { return }
        // Durable previews have no ordering metadata and cannot replace a retained v1 observation.
        // A present malformed extension still follows the separate readonly policy.
        if !NotificationActionPolicy.hasExtension(envelope.payload),
           actionSession?.hasObservedKey(of: envelope) == true { return }
        let offer = NotificationActionOffer(envelope)
        if let offer, actionSession != nil {
            guard let observation = actionSession?.observe(offer) else { return }
            if observation.retireAll { endWaitingAction(); retireActionPresentations() }
            if let key = observation.evicted {
                retireActionPresentations { $0.packageName == key.package && $0.notificationKey == key.notification }
            }
            if let generation = actionSession?.admission.generation, notificationActionsAllowed?(generation) ?? true,
               let enable = actionSession?.enable(now: now()) { onNotificationAction?(enable, generation) }
        }
        let id = offer == nil ? "\(plan.categoryIdentifier)-\(envelope.id)" : "plink.actions.\(UUID().uuidString)"
        let context = ReplyRouter.context(from: envelope)
        if envelope.type == .messageReceived,
           let key = envelope.payload["notificationKey"]?.stringValue {
            let obsolete = envelope.payload["removed"]?.boolValue == true
                ? messages.remove(notificationKey: key, peerID: envelope.sourceDeviceId)
                : messages.store(
                    notificationID: id,
                    peerID: envelope.sourceDeviceId,
                    notificationKey: key,
                    context: context, now: now()
                )
            removeMessages(obsolete)
        }
        if envelope.payload["removed"]?.boolValue == true { return }
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.subtitle = plan.subtitle
        content.body = plan.body
        content.categoryIdentifier = plan.categoryIdentifier == "plink.message" && context == nil ? "plink.message.readonly" : plan.categoryIdentifier
        if let offer, actionSession?.permits(offer, now: now()) == true {
            let category = Self.category(for: offer)
            actionPresentations[id] = ActionPresentation(offer: offer, category: category)
            content.categoryIdentifier = category.identifier
            publishCategories() // Register before add; all currently referenced shapes and call categories survive.
            if offer.overflow > 0 || offer.slots.contains(where: { $0.kind == .phone }) {
                onActionInfo?(Self.explanation(for: offer))
            }
        }
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
        await handleResponse(id: id, action: action, text: text, category: response.notification.request.content.categoryIdentifier)
    }

    // Same action path for native responses and held-delivery regression tests.
    func handleResponse(id: String, action: String, text: String?, category: String? = nil) {
        if action.hasPrefix("call.") {
            callLog.notice("calls.notification.response.call")
        } else if action.hasPrefix("notification.action.") {
            callLog.notice("calls.notification.response.generic")
        } else if action == "message.reply" {
            callLog.notice("calls.notification.response.reply")
        } else if action == UNNotificationDefaultActionIdentifier {
            callLog.notice("calls.notification.response.default")
        } else if action == UNNotificationDismissActionIdentifier {
            callLog.notice("calls.notification.response.dismiss")
        } else {
            callLog.notice("calls.notification.response.other")
        }
        if action.hasPrefix("call."), let callAction = MacCallAction(rawValue: String(action.dropFirst(5))) {
            guard [.answer, .decline, .hangUp].contains(callAction),
                  callPresentationAllowed, !callActionConsumed, id == callNotificationID,
                  let context = callContext, currentCall.permits(callAction, context: context) else {
                callLog.notice("calls.notification.response.call.rejected_context")
                onStaleAction?(); return
            }
            let allowed = callActionsAllowed?() ?? true
            callLog.notice("calls.notification.response.call.eligibility allowed=\(allowed, privacy: .public)")
            guard allowed else {
                callLog.notice("calls.notification.response.call.rejected_eligibility")
                onStaleAction?(); return
            }
            callActionConsumed = true
            removeDeliveredAndPending([id])
            callLog.notice("calls.notification.response.call.accepted")
            onCallAction?(callAction, context)
            return
        }
        if action == UNNotificationDismissActionIdentifier {
            if id == callNotificationID { callActionConsumed = true }
            if id == mirroredCallNotificationID { dismissedMirroredIdentity = mirroredCallIdentity }
            self.removeDeliveredAndPending([id])
            _ = self.messages.remove(notificationID: id)
            callLog.notice("calls.notification.response.dismiss.handled")
            return
        }
        if action == UNNotificationDefaultActionIdentifier, callPresentationAllowed,
           (id == callNotificationID && !callActionConsumed && callContext != nil &&
            currentCall.context == callContext && [.ringing, .active].contains(currentCall.phase) ||
            id == mirroredCallNotificationID && callContext == nil && mirroredCallIdentity != nil) {
            callLog.notice("calls.notification.response.default.accepted")
            onOpenNotification?()
            return
        }
        if action.hasPrefix("notification.action.") {
            handleNotificationAction(id: id, action: action, text: text, category: category)
            return
        }
        if action == UNNotificationDefaultActionIdentifier, messages.containsID(id) {
            if let presentation = actionPresentations[id] { onActionInfo?(Self.explanation(for: presentation.offer)) }
            callLog.notice("calls.notification.response.default.accepted")
            onOpenNotification?()
            return
        }
        if action == UNNotificationDefaultActionIdentifier {
            callLog.notice("calls.notification.response.default.ignored")
        }
        guard action == "message.reply", let text else {
            if action == "message.reply" { callLog.notice("calls.notification.response.reply.rejected_input") }
            return
        }
        do { try ReplyRouter.validateReplyText(text) }
        catch {
            callLog.notice("calls.notification.response.reply.rejected_input")
            self.onInvalidReply?(); return
        }
        guard let context = self.messages.takeReply(notificationID: id) else {
            callLog.notice("calls.notification.response.reply.rejected_authority")
            self.onStaleAction?(); return
        }
        self.removeDeliveredAndPending([id])
        callLog.notice("calls.notification.response.reply.accepted")
        self.onTextReply?(context, text)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    private func submitFromPhone(_ content: UNMutableNotificationContent, id: String,
                                   envelope: PlinkEnvelope, phoneName: String?) {
        content.subtitle = NotificationArtwork.subtitle(appName: envelope.payload["sourceAppName"]?.stringValue,
                                                       phoneName: phoneName)
        if envelope.type == .messageReceived {
            callLog.notice("calls.notification.messageReceived.attachment.none")
        }
        submit(content, id: id)
    }

    private func submit(_ content: UNMutableNotificationContent, id: String) {
        submissions.removeValue(forKey: id)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        // Submission attempts identify the route, not successful delivery or display.
        if content.categoryIdentifier == "plink.call.ringing" || content.categoryIdentifier == "plink.call.active" {
            callLog.notice("calls.notification.submit.hfp")
        } else if content.categoryIdentifier == "plink.call.readonly" {
            callLog.notice("calls.notification.submit.mirrored")
        } else if content.categoryIdentifier.hasPrefix("plink.actions.") ||
                    content.categoryIdentifier == "plink.message" || content.categoryIdentifier == "plink.message.readonly" {
            callLog.notice("calls.notification.submit.generic")
        } else {
            callLog.notice("calls.notification.submit.other")
        }
        if let submitNotification {
            submitNotification(request)
            return
        }
        let token = UUID()
        let trackedMessage = messages.containsID(id)
        submissions[id] = token
        let completion: @MainActor (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            guard self.submissions[id] == token else {
                // An add can finish after privacy/ownership cleanup. HFP presentation IDs
                // are unique, so removing this retired request cannot remove its replacement.
                if id.hasPrefix("plink.hfp."),
                   self.callNotificationID != id || self.callActionConsumed || !self.callPresentationAllowed {
                    self.removeDeliveredAndPending([id])
                } else if id.hasPrefix("plink.call.mirrored."), self.mirroredCallNotificationID != id {
                    self.removeDeliveredAndPending([id])
                } else if trackedMessage, !self.messages.containsID(id) {
                    // A retired add may land after removal; a current same-ID replacement stays owned.
                    self.removeDeliveredAndPending([id])
                }
                return
            }
            self.submissions.removeValue(forKey: id)
            guard let error else { return }
            _ = self.messages.remove(notificationID: id)
            self.retireActionPresentation(id)
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
        pendingMirroredCall = nil
        if let id = mirroredCallNotificationID { removeDeliveredAndPending([id]) }
    }

    private func removeDeliveredAndPending(_ ids: [String]) {
        for id in ids {
            submissions.removeValue(forKey: id)
            retireActionPresentation(id)
            if mirroredCallNotificationID == id {
                mirroredCallNotificationID = nil
                mirroredCallIdentity = nil
            }
        }
        if let removeNotifications { removeNotifications(ids); return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func bindActionAdmission(localID: String, peerID: String, generation: UUID) {
        let admission = NotificationActionSession.Admission(localID: localID, peerID: peerID, generation: generation)
        guard actionSession?.admission != admission else { return }
        clearContexts()
        actionSession = NotificationActionSession(admission: admission)
    }

    /// Called before the legacy command tracker; new outcomes cannot fall through to legacy matching.
    func handleActionControl(_ envelope: PlinkEnvelope) -> Bool {
        guard NotificationActionPolicy.isControl(envelope) else { return false }
        guard let generation = actionSession?.admission.generation,
              notificationActionsAllowed?(generation) ?? true else { return true }
        if envelope.type == .notificationActionsState {
            if actionSession?.state(envelope) == true { endWaitingAction(); retireActionPresentations() }
        } else if let command = actionSession?.outcome(envelope, now: now()),
                  command.presentationID != nil, command.envelope.id == latestActionCommandID {
            latestActionCommandID = nil
            if envelope.type == .ack { onActionInfo?("Phone accepted the action. Delivery is not confirmed.") }
            else { onActionInfo?(NotificationActionPolicy.failureMessage(envelope.payload["code"]?.stringValue ?? "")) }
        }
        return true
    }

    func actionTransportFailed(_ id: String, generation: UUID) {
        guard actionSession?.admission.generation == generation,
              let command = actionSession?.failed(id), command.envelope.id == latestActionCommandID,
              command.presentationID != nil else { return }
        endWaitingAction()
    }

    private func endWaitingAction() {
        guard latestActionCommandID != nil else { return }
        latestActionCommandID = nil
        onActionInfo?("Could not confirm the action.")
    }

    private func handleNotificationAction(id: String, action: String, text: String?, category: String?) {
        guard var presentation = actionPresentations[id], messages.containsID(id),
              category == presentation.category.identifier,
              let index = Int(action.dropFirst("notification.action.".count)),
              action == "notification.action.\(index)", presentation.offer.slots.indices.contains(index),
              !presentation.consumed.contains(index),
              let generation = actionSession?.admission.generation,
              notificationActionsAllowed?(generation) ?? true,
              actionSession?.permits(presentation.offer, now: now()) == true else {
            callLog.notice("calls.notification.response.generic.rejected_authority")
            onStaleAction?(); return
        }
        let slot = presentation.offer.slots[index]
        if slot.kind == .phone {
            callLog.notice("calls.notification.response.generic.phone_only")
            onActionInfo?(Self.phoneExplanation(slot.reason)); return
        }
        let command: PlinkEnvelope
        do { command = try presentation.offer.invocation(index: index, text: text, now: now()) }
        catch {
            callLog.notice("calls.notification.response.generic.rejected_input")
            onInvalidReply?(); return
        }
        guard actionSession?.track(command, presentationID: id, now: now()) == true else {
            callLog.notice("calls.notification.response.generic.rejected_capacity")
            onActionInfo?("Wait for the current actions to finish."); return
        }
        latestActionCommandID = command.id
        presentation.consumed.insert(index)
        actionPresentations[id] = presentation
        onActionInfo?("Waiting for your phone…")
        callLog.notice("calls.notification.response.generic.accepted")
        onNotificationAction?(command, generation)
        callLog.notice("calls.notification.response.generic.handoff_returned")
    }

    private func retireActionPresentations(where predicate: (NotificationActionOffer) -> Bool = { _ in true }) {
        let ids = actionPresentations.filter { predicate($0.value.offer) }.map(\.key)
        for id in ids { _ = messages.remove(notificationID: id) }
        removeMessages(ids)
    }

    private func retireActionPresentation(_ id: String) {
        if actionPresentations.removeValue(forKey: id) != nil { publishCategories() }
    }

    private func publishCategories() {
        let reply = UNTextInputNotificationAction(identifier: "message.reply", title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        var categories = Self.callCategories.union([
            UNNotificationCategory(identifier: "plink.call.readonly", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plink.message", actions: [reply], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: "plink.message.readonly", actions: [], intentIdentifiers: [])
        ])
        categories.formUnion(actionPresentations.values.map(\.category))
        if let registerCategories { registerCategories(categories) }
        else if submitNotification == nil && addNotification == nil { center.setNotificationCategories(categories) }
    }

    private static func category(for offer: NotificationActionOffer) -> UNNotificationCategory {
        // Only immutable presentation fields enter this hash. Tokens and routing never do.
        let shape = offer.slots.map { [$0.label, $0.kind.rawValue, $0.inputLabel ?? "",
                                      $0.authenticationRequired ? "1" : "0", $0.destructive ? "1" : "0"] }
        let data = (try? JSONSerialization.data(withJSONObject: shape)) ?? Data()
        let identifier = "plink.actions." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let actions: [UNNotificationAction] = offer.slots.enumerated().map { index, slot in
            var options: UNNotificationActionOptions = []
            if slot.authenticationRequired { options.insert(.authenticationRequired) }
            if slot.destructive { options.insert(.destructive) }
            let id = "notification.action.\(index)"
            if slot.kind == .text {
                return UNTextInputNotificationAction(identifier: id, title: slot.label, options: options,
                    textInputButtonTitle: "Send", textInputPlaceholder: slot.inputLabel ?? "Message")
            }
            return UNNotificationAction(identifier: id, title: slot.label, options: options)
        }
        return UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [.customDismissAction])
    }

    private static func explanation(for offer: NotificationActionOffer) -> String {
        var parts = offer.slots.filter { $0.kind == .phone }.map { phoneExplanation($0.reason) }
        if offer.overflow > 0 { parts.append("\(offer.overflow) more actions are available on your phone.") }
        return parts.isEmpty ? "Choose an action on the notification." : Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }.joined(separator: " ")
    }

    private static func phoneExplanation(_ reason: String?) -> String {
        switch reason {
        case "choice_input": return "Choose an option on your phone."
        case "data_input": return "Add the requested attachment on your phone."
        case "multiple_inputs": return "Complete the requested fields on your phone."
        case "missing_intent", "invalid_label": return "This action is unavailable here. Check your phone."
        default: return "Complete this action on your phone."
        }
    }

}

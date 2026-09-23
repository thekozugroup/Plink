import Foundation
import AppKit
import IOBluetooth
import IOBluetoothUI
import IOKit
import PlinkCore
import Combine
import OSLog

struct BluetoothPhone: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var isPaired = true
    var supportsCalls = true
}

extension MacCallSession {
    /// Interpret the native result without changing call certainty or confirming an answer.
    mutating func observeSCOOpened(status: Int32?) {
        if status == kIOReturnUnsupported { markComputerAudioUnsupported() }
        if status == 0 { clearComputerAudioUnsupported() }
        setSCO(status == 0)
    }
}

// Shared by explicit setup and fake catalog/selector tests; no native APIs here.
@MainActor
final class BluetoothCallSetup {
    private let setupLog = Logger(subsystem: "com.thekozugroup.plink.mac", category: "bluetooth-calling")
    private var token: UUID?
    private var initialRequestID: UUID?
    private var initialRequest: (isCurrent: () -> Bool, present: () -> Void)?
    var inProgress: Bool { token != nil }

    nonisolated static func canonicalAddress(_ raw: String) -> String? {
        let value = raw.replacingOccurrences(of: "-", with: ":")
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        } }) else { return nil }
        let canonical = parts.joined(separator: ":").uppercased()
        guard canonical != "00:00:00:00:00:00", canonical != "FF:FF:FF:FF:FF:FF" else { return nil }
        return canonical
    }

    nonisolated static func candidates(_ records: [BluetoothPhone]) -> [BluetoothPhone] {
        var seen = Set<String>()
        return records.compactMap { record -> BluetoothPhone? in
            guard record.isPaired, record.supportsCalls, let address = canonicalAddress(record.id),
                  seen.insert(address).inserted else { return nil }
            return BluetoothPhone(id: address, name: record.name)
        }.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated static func matchingSavedPhone(_ address: String, in phones: [BluetoothPhone]) -> BluetoothPhone? {
        guard let address = canonicalAddress(address) else { return nil }
        return candidates(phones).first { $0.id == address }
    }

    nonisolated static func bondedChoice(in snapshot: [BluetoothPhone], popupIndex: Int) -> BluetoothPhone? {
        guard popupIndex > 0, popupIndex <= snapshot.count else { return nil }
        return snapshot[popupIndex - 1] // Index zero is the neutral prompt, never a phone.
    }

    func cancel() { token = nil; initialRequest = nil }

    func queueInitialSetup(id: UUID, isCurrent: @escaping () -> Bool, present: @escaping () -> Void) {
        guard id != initialRequestID, isCurrent() else { return }
        initialRequestID = id
        initialRequest = (isCurrent, present)
    }

    func drainInitialSetup(ready: Bool) {
        guard let request = initialRequest else { return }
        guard request.isCurrent() else { initialRequest = nil; return }
        guard ready else { return }
        initialRequest = nil // Consume before a modal chooser can reenter the run loop.
        request.present()
    }

    func begin(phoneName: String,
               readCatalog: (@escaping @MainActor ([BluetoothPhone]) -> Void) -> Void,
               choose: @escaping (_ isCurrent: () -> Bool) -> BluetoothPhone?, isCurrent: @escaping () -> Bool,
               validate: @escaping (BluetoothPhone) -> Bool, commit: @escaping (BluetoothPhone) -> Void) {
        setupLog.notice("calls.setup.coordinator.enter")
        guard token == nil, isCurrent() else { setupLog.notice("calls.setup.coordinator.rejected"); return }
        let token = UUID()
        self.token = token
        readCatalog { [weak self] _ in
            guard let self else { return }
            self.setupLog.notice("calls.setup.catalog.delivered")
            guard self.token == token else { self.setupLog.notice("calls.setup.catalog.rejected.token"); return }
            defer { if self.token == token { self.token = nil } }
            guard !Task.isCancelled, isCurrent() else { self.setupLog.notice("calls.setup.catalog.rejected.current"); return }
            // A matching display name is not a verified association with the paired peer.
            let selected = choose { self.token == token && !Task.isCancelled && isCurrent() }
            guard self.token == token, !Task.isCancelled, isCurrent(), let selected,
                  let phone = Self.candidates([selected]).first, validate(phone),
                  self.token == token, isCurrent() else { self.setupLog.notice("calls.setup.precommit.rejected"); return }
            self.setupLog.notice("calls.setup.precommit.accepted")
            commit(phone)
        }
    }

    @discardableResult
    static func afterPairingCommit(isCurrent: @escaping () -> Bool, setup: @escaping () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            guard !Task.isCancelled, isCurrent() else { return }
            setup()
        }
    }
}

@MainActor
private final class BondedPhoneChoiceTarget: NSObject {
    let snapshot: [BluetoothPhone]
    let confirm: NSButton

    init(snapshot: [BluetoothPhone], confirm: NSButton) {
        self.snapshot = snapshot
        self.confirm = confirm
        super.init()
    }

    @objc func selectionChanged(_ popup: NSPopUpButton) {
        confirm.isEnabled = BluetoothCallSetup.bondedChoice(in: snapshot, popupIndex: popup.indexOfSelectedItem) != nil
    }
}

@MainActor
final class BluetoothCallController: ObservableObject {
    @Published private(set) var phones: [BluetoothPhone] = []
    @Published private(set) var call = MacCallSession()
    @Published private(set) var status = "Connect your phone to enable calls."
    @Published private(set) var serviceConnected = false
    @Published private(set) var bluetoothPaired = false
    @Published private(set) var busy = false
    @Published private(set) var blocked = false
    var onCallChanged: ((MacCallSession) -> Void)?
    var computerAudioUnavailableReason: String? {
        call.computerAudioUnsupported ? "Mac call audio is unavailable for this connection. Use your phone for audio." : nil
    }
    private let worker = HFPWorker()
    private var gate = MacBluetoothOperationGate()
    private var operation: MacBluetoothOperationGate.Operation? { gate.current }
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    private let peerMapKey = "plink.bluetoothPeers"
    private var configuredPeerID: String?
    private var pendingPeerID: String?
    private var pendingPhoneAddress: String?
    private var pendingPeerConfiguration = false
    private var pendingDiscoveryComplete = false
    private let setup = BluetoothCallSetup()
    private var setupInProgress: Bool { setup.inProgress }
    private var setupCatalogCompletion: (@MainActor ([BluetoothPhone]) -> Void)?
    private let setupLog = Logger(subsystem: "com.thekozugroup.plink.mac", category: "bluetooth-calling")
    private var servicePeerMismatch = false
    private var chooserRequiredPeerID: String?
    private var nativeServiceConnected = false
    private var connectingPhoneAddress: String?
    private var peerRetirement: CheckedContinuation<Bool, Never>?

    func ownsPeer(_ id: String) -> Bool { configuredPeerID == id || pendingPeerID == id }
    var managementUnavailableReason: String? {
        if call.context != nil || !call.stateIsCertain { return "End the call first." }
        if blocked { return "Restart Plink before changing the calling phone." }
        if busy || worker.isBusy || connectingPhoneAddress != nil || setupInProgress || peerRetirement != nil {
            return "Wait for Bluetooth setup to finish."
        }
        return nil
    }

    func cancelInitialSetup() { setup.cancel() }

    func requestInitialSetup(id: UUID, peerID: String, phoneName: String, isCurrent: @escaping () -> Bool) {
        guard !blocked, call.context == nil, call.stateIsCertain,
              association(peerID: peerID) == nil,
              configuredPeerID == peerID || pendingPeerID == peerID else { return }
        setup.queueInitialSetup(id: id, isCurrent: { [weak self] in
            guard let self else { return false }
            return isCurrent() && !self.blocked && self.call.context == nil && self.call.stateIsCertain &&
                (self.configuredPeerID == peerID || self.pendingPeerID == peerID)
        }, present: { [weak self] in self?.beginSetup(phoneName: phoneName) })
        drainInitialSetup()
    }

    private func drainInitialSetup() {
        setup.drainInitialSetup(ready: !busy && !worker.isBusy && gate.current == nil &&
            !servicePeerMismatch && !pendingPeerConfiguration && connectingPhoneAddress == nil &&
            call.phoneID == nil && !setupInProgress && peerRetirement == nil)
    }

    /// Does not delete an OS bond. Await the existing worker's disconnect and return.
    func retireConfiguredPeer() async -> Bool {
        guard managementUnavailableReason == nil else { return false }
        setup.cancel()
        pendingPeerID = nil; pendingPeerConfiguration = false; pendingPhoneAddress = nil
        return await withCheckedContinuation { continuation in
            peerRetirement = continuation
            servicePeerMismatch = true
            serviceConnected = false
            bluetoothPaired = false
            if call.phoneID != nil { disconnectForPeerSwitch() }
            finishPeerRetirement()
        }
    }

    private func finishPeerRetirement() {
        guard let continuation = peerRetirement else { return }
        if blocked {
            peerRetirement = nil
            continuation.resume(returning: false)
            return
        }
        guard !busy, !worker.isBusy, gate.current == nil, call.phoneID == nil,
              connectingPhoneAddress == nil, !nativeServiceConnected else { return }
        peerRetirement = nil
        configuredPeerID = nil; pendingPeerID = nil; servicePeerMismatch = false
        generation = UUID()
        call = MacCallSession()
        onCallChanged?(call)
        continuation.resume(returning: true)
    }

    @discardableResult
    func removeAssociation(peerID: String, expectedAddress: String?) -> Bool {
        Self.removeAssociation(peerID: peerID, expectedAddress: expectedAddress, defaults: .standard)
    }

    @discardableResult
    nonisolated static func removeAssociation(peerID: String, expectedAddress: String?, defaults: UserDefaults) -> Bool {
        let key = "plink.bluetoothPeers"
        var entries = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard entries[peerID] == expectedAddress else { return false }
        entries.removeValue(forKey: peerID)
        defaults.set(entries, forKey: key)
        return true
    }

    func association(peerID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: peerMapKey) as? [String: String])?[peerID]
    }

    init() {
        worker.onEvent = { [weak self] generation, snapshot, message, serviceConnected, completion, endedContext, phoneDisconnected in
            Task { @MainActor in
                guard let self else { return }
                self.setupLog.notice("calls.controller.event currentGeneration=\(generation == self.generation, privacy: .public) blocked=\(self.blocked, privacy: .public) peerMismatch=\(self.servicePeerMismatch, privacy: .public) serviceConnected=\(serviceConnected, privacy: .public)")
                guard generation == self.generation, !self.blocked else { return }
                var snapshot = snapshot
                if self.gate.requiresReconnect { snapshot.markUnconfirmed(context: snapshot.context) }
                let wasMismatched = self.servicePeerMismatch
                self.call = snapshot
                self.connectingPhoneAddress = nil
                self.nativeServiceConnected = serviceConnected
                if let completion {
                    if completion.action != nil && (endedContext != nil || phoneDisconnected) {
                        self.cancelCall(completion)
                    } else {
                        self.finish(completion)
                    }
                } else if let current = self.gate.current,
                          current.generation == generation,
                          current.action != nil,
                          phoneDisconnected || current.context == endedContext {
                    self.cancelCall(current)
                }
                if wasMismatched {
                    if snapshot.context == nil { self.onCallChanged?(MacCallSession()) }
                    if phoneDisconnected || snapshot.phoneID == nil {
                        self.activatePendingPeer()
                    } else if snapshot.context == nil {
                        self.disconnectForPeerSwitch()
                    }
                    self.finishPeerRetirement()
                    self.drainInitialSetup()
                    return
                }
                self.call = snapshot
                self.status = message
                self.serviceConnected = serviceConnected
                self.onCallChanged?(snapshot)
                self.drainInitialSetup()
            }
        }
        worker.onReturned = { [weak self] operation in
            Task { @MainActor in self?.invocationReturned(operation) }
        }
    }

    func configurePairedPhone(peerID: String) {
        if configuredPeerID != peerID { setup.cancel() }
        let savedAddress = pairedPhoneAddresses()[peerID]
        if configuredPeerID != peerID || savedAddress == nil || servicePeerMismatch {
            bluetoothPaired = false
        }
        if !busy, connectingPhoneAddress == nil,
           nativeServiceConnected,
           configuredPeerID == peerID, let savedAddress, let currentAddress = call.phoneID,
           BluetoothCallSetup.canonicalAddress(currentAddress) == savedAddress {
            pendingPeerID = nil
            pendingPhoneAddress = nil
            pendingPeerConfiguration = false
            pendingDiscoveryComplete = false
            servicePeerMismatch = false
            serviceConnected = nativeServiceConnected && !blocked
            return
        }
        if call.context != nil || (servicePeerMismatch && busy) ||
            ((call.phoneID != nil || connectingPhoneAddress != nil) && configuredPeerID != peerID) {
            pendingPeerID = peerID
            pendingPhoneAddress = savedAddress
            pendingPeerConfiguration = true
            pendingDiscoveryComplete = false
            servicePeerMismatch = configuredPeerID != peerID || (servicePeerMismatch && busy)
            if servicePeerMismatch {
                bluetoothPaired = false
                serviceConnected = false
                onCallChanged?(MacCallSession())
            }
            if call.context != nil { status = "Finish the current call before switching phones." }
            else { continuePendingPeerConfiguration() }
            return
        }
        servicePeerMismatch = false
        configuredPeerID = peerID
        pendingPeerID = nil
        pendingPhoneAddress = savedAddress
        pendingPeerConfiguration = true
        pendingDiscoveryComplete = false
        continuePendingPeerConfiguration()
    }

    func beginSetup(phoneName: String) {
        setupLog.notice("calls.setup.controller.enter")
        guard !setupInProgress else { setupLog.notice("calls.setup.rejected.busy"); return }
        guard !blocked else { setupLog.notice("calls.setup.rejected.blocked"); return }
        guard !busy, !worker.isBusy, connectingPhoneAddress == nil else { setupLog.notice("calls.setup.rejected.busy"); return }
        guard !servicePeerMismatch else { setupLog.notice("calls.setup.rejected.stale_pair_generation"); return }
        guard call.context == nil else { setupLog.notice("calls.setup.rejected.active_call"); return }
        guard let peerID = configuredPeerID else {
            setupLog.notice("calls.setup.rejected.no_configured_peer")
            status = "Finish phone pairing before setting up calls."
            return
        }
        if let savedAddress = pairedPhoneAddresses()[peerID], chooserRequiredPeerID != peerID {
            setupLog.notice("calls.setup.saved_association.connect")
            pendingPhoneAddress = savedAddress
            pendingPeerConfiguration = true
            pendingDiscoveryComplete = false
            continuePendingPeerConfiguration()
            return
        }
        bluetoothPaired = false
        let setupGeneration = generation
        setup.begin(phoneName: phoneName, readCatalog: { [weak self] completion in
            self?.readSetupCatalog(completion: completion)
        }, choose: { [weak self] isCurrent in self?.choosePhone(phoneName: phoneName, isCurrent: isCurrent) },
        isCurrent: { [weak self] in
            self?.setupIsCurrent(peerID: peerID, generation: setupGeneration) == true
        }, validate: { [weak self] phone in
            guard let device = IOBluetoothDevice(addressString: phone.id),
                  device.isPaired(), device.isHandsFreeAudioGateway,
                  let actualAddress = device.addressString,
                  BluetoothCallSetup.canonicalAddress(actualAddress) == phone.id else {
                self?.setupLog.notice("calls.setup.rejected.invalid_selection")
                return false
            }
            return true
        }, commit: { [weak self] phone in
            guard let self else { return }
            self.setupLog.notice("calls.setup.commit.enter")
            guard self.setupIsCurrent(peerID: peerID, generation: setupGeneration) else {
                self.setupLog.notice("calls.setup.commit.rejected"); return
            }
            var pairedPhones = self.pairedPhoneAddresses()
            pairedPhones[peerID] = phone.id
            UserDefaults.standard.set(pairedPhones, forKey: self.peerMapKey)
            self.setupLog.notice("calls.setup.association_saved")
            self.bluetoothPaired = true
            self.chooserRequiredPeerID = nil
            self.pendingPeerConfiguration = false
            self.pendingPhoneAddress = nil
            self.phones = [phone]
            self.connect(phone.id)
        })
    }

    private func setupIsCurrent(peerID: String, generation: UUID) -> Bool {
        guard configuredPeerID == peerID, self.generation == generation, !servicePeerMismatch else {
            setupLog.notice("calls.setup.rejected.stale_pair_generation"); return false
        }
        guard !blocked else { setupLog.notice("calls.setup.rejected.blocked"); return false }
        guard !busy, !worker.isBusy, operation == nil, connectingPhoneAddress == nil, call.phoneID == nil else {
            setupLog.notice("calls.setup.rejected.busy"); return false
        }
        guard call.context == nil else { setupLog.notice("calls.setup.rejected.active_call"); return false }
        return true
    }

    private func readSetupCatalog(completion: @escaping @MainActor ([BluetoothPhone]) -> Void) {
        setupLog.notice("calls.setup.catalog.enter")
        guard let operation = start("Reading paired Bluetooth phones…") else {
            setupLog.notice("calls.setup.catalog.rejected.start"); setup.cancel(); return
        }
        guard worker.submit(operation: operation, { [weak self] _ in
            let phones = Self.pairedCatalog()
            Task { @MainActor in
                guard let self else { return }
                self.setupLog.notice("calls.setup.catalog.returned")
                guard self.operation == operation, !self.blocked else {
                    self.setupLog.notice("calls.setup.catalog.rejected.operation"); return
                }
                self.phones = phones
                self.setupCatalogCompletion = completion
                self.finish(operation) // Completion runs only after the native worker invocation has returned.
            }
        }) else {
            setupLog.notice("calls.setup.catalog.rejected.submit"); setup.cancel(); cancelStart(operation); return
        }
    }

    private func choosePhone(phoneName: String, isCurrent: () -> Bool) -> BluetoothPhone? {
        setupLog.notice("calls.setup.picker.enter")
        let snapshot = BluetoothCallSetup.candidates(phones)
        let alert = NSAlert()
        alert.messageText = "Set Up Calls"
        if !snapshot.isEmpty {
            alert.informativeText = "Choose the Bluetooth phone that matches \(phoneName)."
            let confirm = alert.addButton(withTitle: "Connect Calls")
            confirm.isEnabled = false
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "Pair Another Phone…")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28), pullsDown: false)
            popup.addItem(withTitle: "Choose a phone…")
            // Add menu items directly so identical display names keep distinct snapshot indices.
            for phone in snapshot {
                popup.menu?.addItem(NSMenuItem(title: phone.name.isEmpty ? "Bluetooth phone" : phone.name,
                                              action: nil, keyEquivalent: ""))
            }
            popup.selectItem(at: 0)
            popup.setAccessibilityLabel("Bluetooth phone")
            let target = BondedPhoneChoiceTarget(snapshot: snapshot, confirm: confirm)
            popup.target = target
            popup.action = #selector(BondedPhoneChoiceTarget.selectionChanged(_:))
            alert.accessoryView = popup
            alert.window.initialFirstResponder = popup
            setupLog.notice("calls.setup.bonded_picker.present")
            let result = withExtendedLifetime(target) { alert.runModal() }
            if result == .alertFirstButtonReturn,
               let selected = BluetoothCallSetup.bondedChoice(in: snapshot, popupIndex: popup.indexOfSelectedItem) {
                setupLog.notice("calls.setup.bonded_picker.confirmed")
                return selected
            }
            guard result == .alertThirdButtonReturn else {
                setupLog.notice("calls.setup.bonded_picker.cancelled")
                status = "Call setup cancelled."
                return nil
            }
            setupLog.notice("calls.setup.bonded_picker.pair_another")
        } else {
            alert.informativeText = "No paired phone is available for calls. Pair \(phoneName) using Bluetooth to continue."
            alert.addButton(withTitle: "Pair Phone")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            setupLog.notice("calls.setup.pair_phone_prompt.present")
            guard alert.runModal() == .alertFirstButtonReturn else {
                setupLog.notice("calls.setup.pair_phone_prompt.cancelled")
                status = "Call setup cancelled."
                return nil
            }
        }
        guard isCurrent() else {
            setupLog.notice("calls.setup.pair_phone_prompt.rejected.current")
            return nil
        }
        let selector = IOBluetoothDeviceSelectorController()
        selector.setTitle("Connect phone calls")
        selector.setDescriptionText("Select the same phone: \(phoneName).")
        selector.addAllowedUUID(IOBluetoothSDPUUID.uuid16(0x111F))
        setupLog.notice("calls.setup.picker.present")
        let result = selector.runModal()
        guard result == kIOBluetoothUISuccess else {
            if result != kIOBluetoothUIUserCanceledErr {
                setupLog.notice("calls.setup.picker.failed")
                status = "Bluetooth setup could not open. Pair your phone in System Settings, then choose Set Up Calls again."
            } else {
                setupLog.notice("calls.setup.picker.cancelled")
                status = "Call setup cancelled."
            }
            return nil
        }
        setupLog.notice("calls.setup.picker.succeeded")
        guard let selected = (selector.getResults() as? [IOBluetoothDevice])?.first,
              selected.isHandsFreeAudioGateway,
              let address = selected.addressString else {
            status = "The selected phone is not available for calls."
            setupLog.notice("calls.setup.rejected.invalid_selection")
            return nil
        }
        if !selected.isPaired() {
            guard isCurrent() else {
                setupLog.notice("calls.setup.pairing_picker.rejected.current")
                return nil
            }
            let pairing = IOBluetoothPairingController()
            pairing.setTitle("Pair for phone calls")
            pairing.setDescriptionText("Pair the phone you selected: \(selected.name ?? phoneName).")
            pairing.addAllowedUUID(IOBluetoothSDPUUID.uuid16(0x111F))
            setupLog.notice("calls.setup.pairing_picker.present")
            let pairingResult = pairing.runModal()
            if pairingResult == kIOBluetoothUISuccess { setupLog.notice("calls.setup.pairing_picker.succeeded") }
            else if pairingResult == kIOBluetoothUIUserCanceledErr { setupLog.notice("calls.setup.pairing_picker.cancelled") }
            else { setupLog.notice("calls.setup.pairing_picker.failed") }
            guard pairingResult == kIOBluetoothUISuccess,
                  let paired = (pairing.getResults() as? [IOBluetoothDevice])?.first,
                  paired.isPaired(), paired.isHandsFreeAudioGateway,
                  let pairedAddress = paired.addressString,
                  BluetoothCallSetup.canonicalAddress(pairedAddress) != nil,
                  BluetoothCallSetup.canonicalAddress(pairedAddress) == BluetoothCallSetup.canonicalAddress(address) else {
                status = "Call setup was not completed for the selected phone."
                setupLog.notice("calls.setup.rejected.invalid_selection")
                return nil
            }
        }
        guard selected.isPaired() else {
            status = "Pair the selected phone to enable calls."
            setupLog.notice("calls.setup.rejected.invalid_selection")
            return nil
        }
        guard let address = BluetoothCallSetup.canonicalAddress(address) else {
            setupLog.notice("calls.setup.rejected.invalid_selection"); return nil
        }
        setupLog.notice("calls.setup.picker.selection_validated")
        return BluetoothPhone(id: address, name: selected.name ?? "Bluetooth phone")
    }

    nonisolated private static func pairedCatalog() -> [BluetoothPhone] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return BluetoothCallSetup.candidates(devices.compactMap { device in
            guard let address = device.addressString else { return nil }
            return BluetoothPhone(id: address, name: device.name ?? "", isPaired: device.isPaired(),
                                  supportsCalls: device.isHandsFreeAudioGateway)
        })
    }

    func discover() {
        guard !servicePeerMismatch, !busy && !blocked, call.phoneID == nil else { status = "Disconnect calling before scanning again."; return }
        guard let operation = start("Reading paired Bluetooth phones…") else { return }
        guard worker.submit(operation: operation, { [weak self] worker in
            let phones = Self.pairedCatalog()
            Task { @MainActor in
                guard let self, self.operation == operation, !self.blocked else { return }
                self.phones = phones
                let savedAddress = self.configuredPeerID.flatMap { self.pairedPhoneAddresses()[$0] }
                self.bluetoothPaired = !self.servicePeerMismatch && savedAddress.map { address in
                    BluetoothCallSetup.matchingSavedPhone(address, in: phones) != nil
                } == true
                self.status = phones.isEmpty ? "No compatible paired phone found. Pair your phone, then retry." : "Select the intended phone, then connect."
                self.finish(operation)
            }
        }) else { cancelStart(operation); return }
    }

    func connect(_ phoneID: String) {
        guard !servicePeerMismatch, phones.contains(where: { $0.id == phoneID }), !busy && !blocked,
              call.context == nil else { return }
        let generation = UUID()
        guard let operation = start("Connecting to the selected phone…", generation: generation) else { return }
        nativeServiceConnected = false
        serviceConnected = false
        gate.reconnecting()
        self.generation = generation
        connectingPhoneAddress = phoneID
        guard worker.submit(operation: operation, { $0.connect(phoneID: phoneID, generation: generation, operation: operation) }) else {
            connectingPhoneAddress = nil
            cancelStart(operation)
            return
        }
    }

    func disconnect() {
        guard !servicePeerMismatch, call.phoneID != nil, !busy && !blocked else { return }
        guard let operation = start("Disconnecting Bluetooth calling…") else { return }
        guard worker.submit(operation: operation, { $0.disconnect() }) else { cancelStart(operation); return }
    }

    func shutdown() {
        setup.cancel()
        setupCatalogCompletion = nil
        deadline?.cancel()
        deadline = nil
        generation = UUID()
        blocked = true
        finishPeerRetirement()
        busy = false
        nativeServiceConnected = false
        serviceConnected = false
        onCallChanged = nil
        worker.shutdown()
    }

    func perform(_ action: MacCallAction, context: MacCallContext) {
        let traceAudio = action == .answer || action == .computerAudio
        if traceAudio { setupLog.notice("calls.audio.controller.enter action=\(action.rawValue, privacy: .public)") }
        guard !servicePeerMismatch || action == .hangUp else {
            if traceAudio { setupLog.notice("calls.audio.controller.rejected_peer_mismatch") }
            status = "Finish the current call before switching phones."
            return
        }
        guard !gate.requiresReconnect else {
            if traceAudio { setupLog.notice("calls.audio.controller.rejected_requires_reconnect") }
            status = "Disconnect and reconnect Bluetooth calling before retrying."
            return
        }
        if action == .computerAudio, let reason = computerAudioUnavailableReason {
            if traceAudio { setupLog.notice("calls.audio.controller.rejected_unsupported") }
            status = reason
            return
        }
        guard !busy && !blocked, call.permits(action, context: context) else {
            if traceAudio { setupLog.notice("calls.audio.controller.rejected_call_gate") }
            status = "That call action is no longer available."
            return
        }
        guard let operation = start("Requesting \(action.rawValue)…", action: action, context: context) else {
            if traceAudio { setupLog.notice("calls.audio.controller.rejected_start") }
            return
        }
        guard worker.submit(operation: operation, { $0.perform(action, context: context, operation: operation) }) else {
            cancelStart(operation)
            if traceAudio { setupLog.notice("calls.audio.controller.rejected_submission") }
            return
        }
        if traceAudio { setupLog.notice("calls.audio.controller.submitted action=\(action.rawValue, privacy: .public)") }
    }

    private func start(
        _ message: String,
        action: MacCallAction? = nil,
        context: MacCallContext? = nil,
        generation: UUID? = nil
    ) -> MacBluetoothOperationGate.Operation? {
        guard !worker.isBusy else { status = "Bluetooth is still responding. Restart Plink if it remains unavailable."; return nil }
        guard let current = gate.begin(generation: generation ?? self.generation, action: action, context: context) else { return nil }
        busy = true; status = message
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self,
                  let invocation = self.worker.expire(current) else { return }
            self.setup.cancel()
            self.setupCatalogCompletion = nil
            switch self.gate.timeout(current, invocation: invocation) {
            case .quarantined:
                self.blocked = true
                self.busy = false
                self.nativeServiceConnected = false
                self.serviceConnected = false
                self.call.markUnconfirmed(context: current.context)
                self.onCallChanged?(self.call)
                self.status = "Bluetooth stopped responding. Calling is disabled until Plink restarts."
            case .recoverable:
                self.busy = false
                if invocation == .returned, current.action == nil,
                   current.generation == self.generation, self.connectingPhoneAddress != nil {
                    // Native connect returned. Retire its callbacks before allowing a manual retry.
                    self.generation = UUID()
                    self.connectingPhoneAddress = nil
                    self.nativeServiceConnected = false
                    self.serviceConnected = false
                    self.call = MacCallSession()
                    self.status = "Calls did not connect. Try connecting calls again."
                    if self.servicePeerMismatch || self.pendingPeerConfiguration {
                        // Keep the pending peer blocked until the worker detaches the old phone.
                        // Its completion uses the new generation; old callbacks remain rejected.
                        self.deadline = nil
                        guard let cleanup = self.start("Disconnecting Bluetooth calling…") else { return }
                        let generation = self.generation
                        if !self.worker.submit(operation: cleanup, { $0.disconnect(generation: generation) }) {
                            _ = self.gate.abort(cleanup)
                            self.worker.cancel(cleanup)
                            self.deadline?.cancel()
                            self.deadline = nil
                            self.busy = false
                            self.blocked = true
                            self.status = "Bluetooth stopped responding. Calling is disabled until Plink restarts."
                        }
                        return
                    }
                } else {
                    self.status = "Phone did not confirm the request. Disconnect and reconnect Bluetooth calling before another call action."
                }
                self.call.markUnconfirmed(context: current.context)
                self.onCallChanged?(self.call)
            case .completed:
                self.busy = false
            case .ignored:
                break
            }
            self.deadline = nil
            self.finishPeerRetirement()
            if let continuation = self.peerRetirement {
                self.peerRetirement = nil
                continuation.resume(returning: false) // Keep mismatch quarantine; never pretend teardown completed.
            }
        }
        return current
    }

    private func finish(_ completed: MacBluetoothOperationGate.Operation) {
        guard let invocation = worker.state(of: completed) else { return }
        guard gate.confirm(completed, invocation: invocation) else { return }
        worker.release(completed)
        finishUI()
    }

    private func invocationReturned(_ returned: MacBluetoothOperationGate.Operation) {
        guard gate.invocationReturned(returned) else { return }
        worker.release(returned)
        finishUI()
    }

    private func cancelCall(_ operation: MacBluetoothOperationGate.Operation) {
        guard let invocation = worker.cancel(operation) else { return }
        if gate.cancelCall(operation, invocation: invocation) { finishUI() }
    }

    private func finishUI() {
        busy = false; deadline?.cancel(); deadline = nil
        let completion = setupCatalogCompletion
        setupCatalogCompletion = nil
        completion?(phones)
        continuePendingPeerConfiguration()
        finishPeerRetirement()
        drainInitialSetup()
    }

    private func cancelStart(_ operation: MacBluetoothOperationGate.Operation) {
        _ = gate.abort(operation)
        worker.cancel(operation)
        finishUI()
    }

    private func pairedPhoneAddresses() -> [String: String] {
        let saved = UserDefaults.standard.dictionary(forKey: peerMapKey) as? [String: String] ?? [:]
        return saved.compactMapValues(BluetoothCallSetup.canonicalAddress)
    }

    private func activatePendingPeer() {
        guard connectingPhoneAddress == nil, call.context == nil, let pendingPeerID else { return }
        bluetoothPaired = false
        configuredPeerID = pendingPeerID
        self.pendingPeerID = nil
        servicePeerMismatch = false
        serviceConnected = false
        continuePendingPeerConfiguration()
    }

    private func disconnectForPeerSwitch() {
        guard call.phoneID != nil, !busy && !blocked else { return }
        guard let operation = start("Disconnecting Bluetooth calling…") else { return }
        guard worker.submit(operation: operation, { $0.disconnect() }) else { cancelStart(operation); return }
    }

    private func continuePendingPeerConfiguration() {
        guard pendingPeerConfiguration, !busy, !blocked, !worker.isBusy,
              gate.current == nil, connectingPhoneAddress == nil, call.context == nil else { return }
        if servicePeerMismatch {
            bluetoothPaired = false
            if call.phoneID == nil { activatePendingPeer() }
            else { disconnectForPeerSwitch() }
            return
        }
        if let currentAddress = call.phoneID {
            if serviceConnected, let pendingPhoneAddress,
               BluetoothCallSetup.canonicalAddress(currentAddress) == pendingPhoneAddress {
                pendingPeerConfiguration = false
                self.pendingPhoneAddress = nil
                return
            }
            disconnect()
            return
        }
        guard let address = pendingPhoneAddress else {
            bluetoothPaired = false
            pendingPeerConfiguration = false
            status = "Set up Bluetooth calls for this phone."
            drainInitialSetup()
            return
        }
        guard pendingDiscoveryComplete else {
            pendingDiscoveryComplete = true
            discover()
            return
        }
        guard let phone = BluetoothCallSetup.matchingSavedPhone(address, in: phones) else {
            bluetoothPaired = false
            pendingPeerConfiguration = false
            pendingPhoneAddress = nil
            chooserRequiredPeerID = configuredPeerID
            status = "Bluetooth call setup is required for this phone."
            return
        }
        pendingPeerConfiguration = false
        pendingPhoneAddress = nil
        connect(phone.id)
    }
}

/// All IOBluetooth objects and delegate callbacks belong to one run-loop thread.
/// No Bluetooth API is invoked by initialization or by tests.
private final class HFPWorker: NSObject, IOBluetoothHandsFreeDeviceDelegate, @unchecked Sendable {
    typealias Operation = MacBluetoothOperationGate.Operation
    typealias InvocationState = MacBluetoothOperationGate.InvocationState

    var onEvent: (@Sendable (UUID, MacCallSession, String, Bool, Operation?, MacCallContext?, Bool) -> Void)?
    var onReturned: (@Sendable (Operation) -> Void)?
    private let lock = NSLock()
    private var work = MacBluetoothOperationGate.WorkTracker()
    private var stopping = false
    private var thread: Thread!
    private var phone: IOBluetoothHandsFreeDevice?
    private var session = MacCallSession()
    private var serviceConnected = false
    private var generation = UUID()
    private var pendingOperation: Operation?
    private var invalidatedOperations: Set<UUID> = []
    private var uncertainCalls: Set<UUID> = []
    private var audioFailureDiagnostic = NativeAudioFailureDiagnostic()
    private var transferInvocationInProgress = false
    private let callLog = Logger(subsystem: "com.thekozugroup.plink.mac", category: "bluetooth-calling")

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return work.operation != nil }

    override init() {
        super.init()
        thread = Thread {
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            while !Thread.current.isCancelled { RunLoop.current.run(until: Date(timeIntervalSinceNow: 60)) }
        }
        thread.name = "Plink Bluetooth"
        thread.start()
    }

    private final class Work: NSObject, @unchecked Sendable {
        let operation: Operation
        let body: @Sendable (HFPWorker) -> Void
        init(operation: Operation, body: @escaping @Sendable (HFPWorker) -> Void) {
            self.operation = operation
            self.body = body
        }
    }

    @discardableResult
    func submit(operation: Operation, _ body: @escaping @Sendable (HFPWorker) -> Void) -> Bool {
        lock.lock()
        guard !stopping, work.enqueue(operation) else { lock.unlock(); return false }
        lock.unlock()
        perform(#selector(run(_:)), on: thread, with: Work(operation: operation, body: body), waitUntilDone: false)
        return true
    }

    @objc private func run(_ queued: Work) {
        lock.lock()
        let shouldRun = !stopping && work.start(queued.operation)
        lock.unlock()
        guard shouldRun else { return }
        queued.body(self)
        lock.lock()
        let returned = work.returned(queued.operation)
        lock.unlock()
        if returned { onReturned?(queued.operation) }
    }

    func state(of operation: Operation) -> InvocationState? {
        lock.lock(); defer { lock.unlock() }
        return work.state(of: operation)
    }

    @discardableResult
    func release(_ operation: Operation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return work.release(operation)
    }

    @discardableResult
    func cancel(_ operation: Operation) -> InvocationState? {
        lock.lock(); defer { lock.unlock() }
        guard let state = work.cancel(operation) else { return nil }
        invalidatedOperations.insert(operation.id)
        return state
    }

    @discardableResult
    func expire(_ operation: Operation) -> InvocationState? {
        lock.lock(); defer { lock.unlock() }
        guard let state = work.expire(operation) else { return nil }
        invalidatedOperations.insert(operation.id)
        if let context = operation.context { uncertainCalls.insert(context.callID) }
        return state
    }

    func shutdown() {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true
        lock.unlock()
        // Best effort on the owning thread. Never wait for a stuck Bluetooth API
        // during Quit or logout; process exit releases remaining native resources.
        perform(#selector(stopOnThread), on: thread, with: nil, waitUntilDone: false)
    }

    @objc private func stopOnThread() {
        onEvent = nil
        onReturned = nil
        thread.cancel()
        phone?.delegate = nil
        phone?.disconnect()
        phone = nil
        serviceConnected = false
    }

    func connect(phoneID: String, generation: UUID, operation: Operation) {
        phone?.delegate = nil
        guard permitsNextStep(operation) else { return }
        phone?.disconnect()
        phone = nil
        serviceConnected = false
        guard permitsNextStep(operation) else { return }
        self.generation = generation
        lock.lock()
        pendingOperation = nil
        uncertainCalls.removeAll()
        lock.unlock()
        session.disconnected()
        guard let device = IOBluetoothDevice(addressString: phoneID), device.isPaired(), device.isHandsFreeAudioGateway else {
            emit("Selected phone is unavailable or does not support calls.", completed: true); return
        }
        guard permitsNextStep(operation) else { return }
        session.connected(phoneID: phoneID)
        phone = IOBluetoothHandsFreeDevice(device: device, delegate: self)
        guard let phone else { session.disconnected(); emit("Could not initialize Bluetooth calling.", completed: true); return }
        guard permitsNextStep(operation) else { return }
        callLog.notice("calls.worker.connect_requested")
        phone.connect()
        callLog.notice("calls.worker.connect_invocation_returned")
    }

    func disconnect(generation: UUID? = nil) {
        phone?.delegate = nil
        phone?.disconnect()
        phone = nil
        if let generation { self.generation = generation }
        serviceConnected = false
        lock.lock()
        pendingOperation = nil
        uncertainCalls.removeAll()
        lock.unlock()
        session.disconnected()
        emit("Bluetooth calling disconnected.", completed: true)
    }

    func perform(_ action: MacCallAction, context: MacCallContext, operation: Operation) {
        let traceAudio = action == .answer || action == .computerAudio
        if traceAudio { callLog.notice("calls.audio.worker.enter action=\(action.rawValue, privacy: .public)") }
        guard let phone, phone.isConnected, session.begin(action, context: context) else {
            if traceAudio { callLog.notice("calls.audio.worker.rejected_native_gate") }
            let message = action == .computerAudio && session.computerAudioUnsupported
                ? "Mac call audio is unavailable for this connection. Use your phone for audio."
                : "Call changed; action ignored."
            emit(message, completion: operation); return
        }
        if traceAudio { callLog.notice("calls.audio.worker.accepted_native_gate") }
        lock.lock()
        guard !stopping, work.permitsNextStep(operation) else {
            lock.unlock()
            if traceAudio { callLog.notice("calls.audio.worker.rejected_work_gate") }
            return
        }
        pendingOperation = operation
        lock.unlock()
        emit("Waiting for phone confirmation…")
        switch action {
        case .answer:
            callLog.notice("calls.audio.answer.accept_requested")
            phone.acceptCall()
            callLog.notice("calls.audio.answer.accept_invocation_returned")
            guard permitsNextStep(operation) else {
                callLog.notice("calls.audio.answer.rejected_work")
                return
            }
            guard session.context == context else {
                callLog.notice("calls.audio.answer.rejected_context")
                return
            }
            if !session.computerAudioUnsupported {
                callLog.notice("calls.audio.answer.transfer_requested")
                transferAudioToComputer(phone)
                callLog.notice("calls.audio.answer.transfer_invocation_returned")
            } else {
                callLog.notice("calls.audio.answer.transfer_skipped_unsupported")
            }
        case .decline, .hangUp: phone.endCall()
        case .computerAudio:
            callLog.notice("calls.audio.computer.transfer_requested")
            transferAudioToComputer(phone)
            callLog.notice("calls.audio.computer.transfer_invocation_returned")
            if phone.isSCOConnected() {
                session.setSCO(true)
                session.setMuted(phone.isInputMuted)
                clearPending(operation)
                emit("Bluetooth audio connected; two-way laptop audio has not been verified.", completion: operation)
            }
        case .phoneAudio:
            phone.transferAudioToPhone()
            if !phone.isSCOConnected() { session.setSCO(false); clearPending(operation); emit("Bluetooth audio disconnected; check the phone route.", completion: operation) }
        case .toggleMute:
            let muted = phone.isInputMuted
            guard permitsNextStep(operation), session.context == context else { return }
            phone.isInputMuted = !muted
            guard permitsNextStep(operation), session.context == context else { return }
            session.setMuted(phone.isInputMuted)
            clearPending(operation)
            emit(session.muted ? "Mac microphone muted." : "Mac microphone unmuted.", completion: operation)
        }
    }

    private func permitsNextStep(_ operation: Operation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopping && work.permitsNextStep(operation)
    }

    private func emit(
        _ message: String,
        completed: Bool = false,
        completion: Operation? = nil,
        endedContext: MacCallContext? = nil,
        phoneDisconnected: Bool = false
    ) {
        var snapshot = session
        if isUncertain(snapshot.context) { snapshot.markUnconfirmed(context: snapshot.context) }
        onEvent?(generation, snapshot, message, serviceConnected, completion ?? (completed ? workOperation() : nil), endedContext, phoneDisconnected)
    }
    private func workOperation() -> Operation? {
        lock.lock(); defer { lock.unlock() }
        return work.operation
    }
    private func completePending(on observation: MacCallAction.Observation) -> Operation? {
        lock.lock(); defer { lock.unlock() }
        guard let pendingOperation, !invalidatedOperations.contains(pendingOperation.id),
              pendingOperation.generation == generation,
              (pendingOperation.context == session.context || observation == .callEnded),
              pendingOperation.action?.completes(on: observation) == true else { return nil }
        self.pendingOperation = nil
        return pendingOperation
    }
    private func clearPending(_ operation: Operation) {
        lock.lock(); defer { lock.unlock() }
        if pendingOperation == operation { pendingOperation = nil }
    }
    private func isUncertain(_ context: MacCallContext?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return context.map { uncertainCalls.contains($0.callID) } ?? false
    }
    private func applyUncertainty() {
        if isUncertain(session.context) { session.markUnconfirmed(context: session.context) }
    }
    private func resolve(_ context: MacCallContext?) {
        guard let context else { return }
        lock.lock(); uncertainCalls.remove(context.callID); lock.unlock()
    }
    private func owns(_ device: IOBluetoothHandsFree?) -> Bool { device != nil && device === phone }

    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        guard owns(device) else { return }
        callLog.notice("calls.worker.connected_callback status=\(status?.intValue ?? -1, privacy: .public)")
        if status?.int32Value == 0 {
            serviceConnected = true
            emit("Phone connected. Waiting for calls.", completed: true)
            if phone?.indicator(IOBluetoothHandsFreeIndicatorCall) == 1 { session.setActive(true) }
            if phone?.indicator(IOBluetoothHandsFreeIndicatorCallSetup) == 1 { session.ringing(number: nil) }
            if session.context != nil {
                session.setSCO(phone?.isSCOConnected() == true)
                session.setMuted(phone?.isInputMuted == true)
                emit("Current phone call detected.")
            }
            phone?.currentCallList()
        } else {
            serviceConnected = false
            session.disconnected()
            emit("Phone call connection failed (\(status?.intValue ?? -1)).", completed: true)
        }
    }
    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        guard owns(device) else { return }
        callLog.notice("calls.worker.disconnected_callback status=\(status?.intValue ?? -1, privacy: .public)")
        let endedContext = session.context
        let completion = completePending(on: .callEnded)
        serviceConnected = false
        session.disconnected()
        lock.lock(); uncertainCalls.removeAll(); lock.unlock()
        emit("Phone disconnected. Reconnect to enable calling.", completion: completion ?? workOperation(), endedContext: endedContext, phoneDisconnected: true)
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        callLog.notice("calls.worker.sco_opened status=\(status?.intValue ?? -1, privacy: .public) owned=\(self.owns(device), privacy: .public)")
        guard owns(device) else { return }
        if audioFailureDiagnostic.shouldCapture(owned: true, status: status?.int32Value) {
            let record = NativeAudioFailureDiagnostic.capture(transferInProgress: transferInvocationInProgress)
            callLog.notice("\(record.logLine, privacy: .public)")
        }
        let success = status?.int32Value == 0
        session.observeSCOOpened(status: status?.int32Value)
        if success { session.setMuted(phone?.isInputMuted == true) }
        let completion = completePending(on: .sco(connected: success))
        let message = success ? "Bluetooth audio connected; two-way laptop audio has not been verified."
            : session.computerAudioUnsupported ? "Mac call audio is unavailable for this connection. Use your phone for audio."
            : "Bluetooth audio connection failed. Use phone audio or reconnect."
        emit(message, completion: completion)
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        callLog.notice("calls.worker.sco_closed status=\(status?.intValue ?? -1, privacy: .public) owned=\(self.owns(device), privacy: .public)")
        guard owns(device) else { return }
        session.setSCO(false)
        let completion = completePending(on: .sco(connected: false))
        emit("Bluetooth audio disconnected; check the phone audio route.", completion: completion)
    }

    private func transferAudioToComputer(_ phone: IOBluetoothHandsFreeDevice) {
        let previous = transferInvocationInProgress
        transferInvocationInProgress = true
        defer { transferInvocationInProgress = previous }
        phone.transferAudioToComputer()
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        callLog.notice("calls.worker.incoming_call owned=\(self.owns(device), privacy: .public)")
        guard owns(device) else { return }
        session.ringing(number: number)
        emit(session.hasWaitingCall ? "Call waiting; manage multiple calls on the phone." : "Incoming call")
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt count: NSNumber!) {
        callLog.notice("calls.worker.ring count=\(count?.intValue ?? -1, privacy: .public) owned=\(self.owns(device), privacy: .public)")
        guard owns(device) else { return }
        session.ringing(number: nil)
        emit("Incoming call")
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode mode: NSNumber!) {
        callLog.notice("calls.worker.call_setup mode=\(mode?.intValue ?? -1, privacy: .public) owned=\(self.owns(device), privacy: .public)")
        guard owns(device) else { return }
        if mode?.intValue == 1 { session.ringing(number: nil); emit("Incoming call") }
        if mode?.intValue == 0 {
            let endedContext = session.context
            session.setupEnded()
            let completion = session.context == nil ? completePending(on: .callEnded) : nil
            emit(session.context == nil ? "Call ended." : "Call active.", completion: completion, endedContext: session.context == nil ? endedContext : nil)
        }
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive active: NSNumber!) {
        callLog.notice("calls.worker.call_active active=\(active?.intValue ?? -1, privacy: .public) owned=\(self.owns(device), privacy: .public)")
        guard owns(device) else { return }
        let isActive = active?.boolValue == true
        let endedContext = isActive ? nil : session.context
        let completion = completePending(on: isActive ? .callActive : .callEnded)
        session.setActive(isActive)
        if isActive {
            session.setSCO(phone?.isSCOConnected() == true)
            session.setMuted(phone?.isInputMuted == true)
        }
        if !isActive { resolve(endedContext) }
        applyUncertainty()
        let message = isActive
            ? (session.computerAudioUnsupported ? "Call active. Use your phone for audio." : "Call active; check laptop audio.")
            : "Call ended."
        emit(message, completion: completion, endedContext: endedContext)
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall call: [AnyHashable: Any]!) {
        let observedStatus = (call?[IOBluetoothHandsFreeCallStatus] as? NSNumber)?.intValue ?? -1
        callLog.notice("calls.worker.current_call status=\(observedStatus, privacy: .public) owned=\(self.owns(device), privacy: .public)")
        guard owns(device), let call,
              let status = call[IOBluetoothHandsFreeCallStatus] as? NSNumber else { return }
        session.observeCall(index: (call[IOBluetoothHandsFreeCallIndex] as? NSNumber)?.intValue, status: status.intValue)
        if status.intValue == 0 {
            session.setSCO(phone?.isSCOConnected() == true)
            session.setMuted(phone?.isInputMuted == true)
        }
        if status.intValue == 0, !session.hasWaitingCall { resolve(session.context) }
        applyUncertainty()
        emit(session.hasWaitingCall ? "Multiple calls; manage calls on the phone." : "Phone call state received.")
    }
}

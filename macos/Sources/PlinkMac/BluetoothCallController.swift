import Foundation
import IOBluetooth
import IOBluetoothUI
import PlinkCore
import Combine

struct BluetoothPhone: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor
final class BluetoothCallController: ObservableObject {
    @Published private(set) var phones: [BluetoothPhone] = []
    @Published private(set) var call = MacCallSession()
    @Published private(set) var status = "Connect your phone to enable calls."
    @Published private(set) var serviceConnected = false
    @Published private(set) var busy = false
    @Published private(set) var blocked = false
    var onCallChanged: ((MacCallSession) -> Void)?
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
    private var setupInProgress = false
    private var servicePeerMismatch = false
    private var chooserRequiredPeerID: String?
    private var nativeServiceConnected = false
    private var connectingPhoneAddress: String?

    init() {
        worker.onEvent = { [weak self] generation, snapshot, message, serviceConnected, completion, endedContext, phoneDisconnected in
            Task { @MainActor in
                guard let self, generation == self.generation, !self.blocked else { return }
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
                    return
                }
                self.call = snapshot
                self.status = message
                self.serviceConnected = serviceConnected
                self.onCallChanged?(snapshot)
            }
        }
        worker.onReturned = { [weak self] operation in
            Task { @MainActor in self?.invocationReturned(operation) }
        }
    }

    func configurePairedPhone(peerID: String) {
        let savedAddress = pairedPhoneAddresses()[peerID]
        if !busy, connectingPhoneAddress == nil,
           configuredPeerID == peerID, let savedAddress, let currentAddress = call.phoneID,
           currentAddress.caseInsensitiveCompare(savedAddress) == .orderedSame {
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
        guard !setupInProgress, !busy && !blocked, !servicePeerMismatch,
              call.context == nil else { return }
        guard let peerID = configuredPeerID else {
            status = "Finish phone pairing before setting up calls."
            return
        }
        if let savedAddress = pairedPhoneAddresses()[peerID], chooserRequiredPeerID != peerID {
            pendingPhoneAddress = savedAddress
            pendingPeerConfiguration = true
            pendingDiscoveryComplete = false
            continuePendingPeerConfiguration()
            return
        }
        let setupGeneration = generation
        setupInProgress = true
        defer { setupInProgress = false }
        let controller = IOBluetoothPairingController()
        controller.setTitle("Connect phone calls")
        controller.setDescriptionText("Select the same phone: \(phoneName).")
        controller.addAllowedUUID(IOBluetoothSDPUUID.uuid16(0x111F))
        let result = controller.runModal()
        guard result == kIOBluetoothUISuccess else {
            if result != kIOBluetoothUIUserCanceledErr {
                status = "Bluetooth phone setup did not complete."
            }
            return
        }
        guard let selected = (controller.getResults() as? [IOBluetoothDevice])?.first,
              selected.isPaired(), selected.isHandsFreeAudioGateway,
              let address = selected.addressString else {
            status = "The selected phone is not available for calls."
            return
        }
        guard configuredPeerID == peerID, generation == setupGeneration,
              !blocked, !busy, call.context == nil else { return }
        let phone = BluetoothPhone(id: address, name: selected.name ?? "Bluetooth phone")
        var pairedPhones = pairedPhoneAddresses()
        pairedPhones[peerID] = address
        UserDefaults.standard.set(pairedPhones, forKey: peerMapKey)
        chooserRequiredPeerID = nil
        pendingPeerConfiguration = false
        pendingPhoneAddress = nil
        phones = [phone]
        connect(phone.id)
    }

    func discover() {
        guard !servicePeerMismatch, !busy && !blocked, call.phoneID == nil else { status = "Disconnect calling before scanning again."; return }
        guard let operation = start("Reading paired Bluetooth phones…") else { return }
        guard worker.submit(operation: operation, { [weak self] worker in
            let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            let phones = devices.compactMap { device -> BluetoothPhone? in
                guard device.isPaired(), device.isHandsFreeAudioGateway,
                      let address = device.addressString else { return nil }
                return BluetoothPhone(id: address, name: device.name ?? "Bluetooth phone")
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                guard let self, self.operation == operation, !self.blocked else { return }
                self.phones = phones
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
        deadline?.cancel()
        deadline = nil
        generation = UUID()
        blocked = true
        busy = false
        nativeServiceConnected = false
        serviceConnected = false
        onCallChanged = nil
        worker.shutdown()
    }

    func perform(_ action: MacCallAction, context: MacCallContext) {
        guard !servicePeerMismatch || action == .hangUp else {
            status = "Finish the current call before switching phones."
            return
        }
        guard !gate.requiresReconnect else {
            status = "Disconnect and reconnect Bluetooth calling before retrying."
            return
        }
        guard !busy && !blocked, call.permits(action, context: context) else {
            status = "That call action is no longer available."
            return
        }
        guard let operation = start("Requesting \(action.rawValue)…", action: action, context: context) else { return }
        guard worker.submit(operation: operation, { $0.perform(action, context: context, operation: operation) }) else { cancelStart(operation); return }
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
                self.call.markUnconfirmed(context: current.context)
                self.onCallChanged?(self.call)
                self.status = "Phone did not confirm the request. Disconnect and reconnect Bluetooth calling before another call action."
            case .completed:
                self.busy = false
            case .ignored:
                break
            }
            self.deadline = nil
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
        continuePendingPeerConfiguration()
    }

    private func cancelStart(_ operation: MacBluetoothOperationGate.Operation) {
        _ = gate.abort(operation)
        worker.cancel(operation)
        finishUI()
    }

    private func pairedPhoneAddresses() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: peerMapKey) as? [String: String] ?? [:]
    }

    private func activatePendingPeer() {
        guard connectingPhoneAddress == nil, call.context == nil, let pendingPeerID else { return }
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
            if call.phoneID == nil { activatePendingPeer() }
            else { disconnectForPeerSwitch() }
            return
        }
        if let currentAddress = call.phoneID {
            if let pendingPhoneAddress,
               currentAddress.caseInsensitiveCompare(pendingPhoneAddress) == .orderedSame {
                pendingPeerConfiguration = false
                self.pendingPhoneAddress = nil
                return
            }
            disconnect()
            return
        }
        guard let address = pendingPhoneAddress else {
            pendingPeerConfiguration = false
            status = "Set up Bluetooth calls for this phone."
            return
        }
        guard pendingDiscoveryComplete else {
            pendingDiscoveryComplete = true
            discover()
            return
        }
        guard let phone = phones.first(where: { $0.id.caseInsensitiveCompare(address) == .orderedSame }) else {
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
        phone.connect()
    }

    func disconnect() {
        phone?.delegate = nil
        phone?.disconnect()
        phone = nil
        serviceConnected = false
        lock.lock()
        pendingOperation = nil
        uncertainCalls.removeAll()
        lock.unlock()
        session.disconnected()
        emit("Bluetooth calling disconnected.", completed: true)
    }

    func perform(_ action: MacCallAction, context: MacCallContext, operation: Operation) {
        guard let phone, phone.isConnected, session.begin(action, context: context) else {
            emit("Call changed; action ignored.", completion: operation); return
        }
        lock.lock()
        guard !stopping, work.permitsNextStep(operation) else { lock.unlock(); return }
        pendingOperation = operation
        lock.unlock()
        emit("Waiting for phone confirmation…")
        switch action {
        case .answer:
            phone.acceptCall()
            guard permitsNextStep(operation), session.context == context else { return }
            phone.transferAudioToComputer()
        case .decline, .hangUp: phone.endCall()
        case .computerAudio:
            phone.transferAudioToComputer()
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
        let endedContext = session.context
        let completion = completePending(on: .callEnded)
        serviceConnected = false
        session.disconnected()
        lock.lock(); uncertainCalls.removeAll(); lock.unlock()
        emit("Phone disconnected. Reconnect to enable calling.", completion: completion ?? workOperation(), endedContext: endedContext, phoneDisconnected: true)
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        guard owns(device) else { return }
        let success = status?.int32Value == 0
        session.setSCO(success)
        if success { session.setMuted(phone?.isInputMuted == true) }
        let completion = completePending(on: .sco(connected: success))
        emit(success ? "Bluetooth audio connected; two-way laptop audio has not been verified." : "Bluetooth audio connection failed. Use phone audio or reconnect.", completion: completion)
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        guard owns(device) else { return }
        session.setSCO(false)
        let completion = completePending(on: .sco(connected: false))
        emit("Bluetooth audio disconnected; check the phone audio route.", completion: completion)
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        guard owns(device) else { return }
        session.ringing(number: number)
        emit(session.hasWaitingCall ? "Call waiting; manage multiple calls on the phone." : "Incoming call")
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt count: NSNumber!) {
        guard owns(device) else { return }
        session.ringing(number: nil)
        emit("Incoming call")
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode mode: NSNumber!) {
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
        emit(isActive ? "Call active; check laptop audio." : "Call ended.", completion: completion, endedContext: endedContext)
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall call: [AnyHashable: Any]!) {
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

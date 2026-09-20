import Foundation
import IOBluetooth
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
    @Published private(set) var status = "Choose your paired Bluetooth phone to enable calling."
    @Published private(set) var busy = false
    @Published private(set) var blocked = false
    var onCallChanged: ((MacCallSession) -> Void)?
    private let worker = HFPWorker()
    private var gate = MacBluetoothOperationGate()
    private var operation: UUID? { gate.current }
    private var generation = UUID()
    private var deadline: Task<Void, Never>?

    init() {
        worker.onEvent = { [weak self] generation, snapshot, message, completed in
            Task { @MainActor in
                guard let self, generation == self.generation, !self.blocked else { return }
                self.call = snapshot
                self.status = message
                if completed { self.finish() }
                self.onCallChanged?(snapshot)
            }
        }
    }

    func discover() {
        guard !busy && !blocked, call.phoneID == nil else { status = "Disconnect calling before scanning again."; return }
        guard start("Reading paired Bluetooth phones…") else { return }
        let operation = operation
        worker.submit { [weak self] worker in
            let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            let phones = devices.compactMap { device -> BluetoothPhone? in
                guard device.isPaired(), device.isHandsFreeAudioGateway,
                      let address = device.addressString else { return nil }
                return BluetoothPhone(id: address, name: device.name ?? "Bluetooth phone")
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                guard let self, self.operation == operation, !self.blocked else { return }
                self.phones = phones
                self.status = phones.isEmpty ? "No paired HFP phone found. Pair your Pixel in Bluetooth settings, then retry." : "Select the intended phone, then connect."
                self.finish()
            }
        }
    }

    func connect(_ phoneID: String) {
        guard phones.contains(where: { $0.id == phoneID }), !busy && !blocked,
              call.context == nil else { return }
        guard start("Connecting to the selected phone…") else { return }
        generation = UUID()
        let generation = generation
        worker.submit { $0.connect(phoneID: phoneID, generation: generation) }
    }

    func disconnect() {
        guard call.phoneID != nil, !busy && !blocked else { return }
        guard start("Disconnecting Bluetooth calling…") else { return }
        worker.submit { $0.disconnect() }
    }

    func shutdown() {
        deadline?.cancel()
        deadline = nil
        generation = UUID()
        blocked = true
        busy = false
        onCallChanged = nil
        worker.shutdown()
    }

    func perform(_ action: MacCallAction, context: MacCallContext) {
        guard !busy && !blocked, call.permits(action, context: context) else {
            status = "That call action is no longer available."
            return
        }
        guard start("Requesting \(action.rawValue)…") else { return }
        worker.submit { $0.perform(action, context: context) }
    }

    private func start(_ message: String) -> Bool {
        guard !worker.isExecuting else { status = "Bluetooth is still responding. Restart Plink if it remains unavailable."; return false }
        guard let current = gate.begin() else { return false }
        busy = true; status = message
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.gate.timeout(current) else { return }
            self.blocked = true
            self.busy = false
            self.call.disconnected()
            self.onCallChanged?(self.call)
            self.status = "Bluetooth timed out. Calling is disabled until Plink restarts. Check Bluetooth permission in System Settings."
            // A framework call cannot be cancelled safely. Keep the single worker;
            // never create replacement threads or queue more work behind a hung call.
        }
        return true
    }

    private func finish() {
        guard let operation, gate.complete(operation) else { return }
        busy = false; deadline?.cancel(); deadline = nil
    }
}

/// All IOBluetooth objects and delegate callbacks belong to one run-loop thread.
/// No Bluetooth API is invoked by initialization or by tests.
private final class HFPWorker: NSObject, IOBluetoothHandsFreeDeviceDelegate, @unchecked Sendable {
    var onEvent: (@Sendable (UUID, MacCallSession, String, Bool) -> Void)?
    private let lock = NSLock()
    private var executing = false
    private var stopping = false
    private var thread: Thread!
    private var phone: IOBluetoothHandsFreeDevice?
    private var session = MacCallSession()
    private var generation = UUID()
    private var pendingAction: MacCallAction?

    var isExecuting: Bool { lock.lock(); defer { lock.unlock() }; return executing }

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
        let body: @Sendable (HFPWorker) -> Void
        init(_ body: @escaping @Sendable (HFPWorker) -> Void) { self.body = body }
    }

    func submit(_ body: @escaping @Sendable (HFPWorker) -> Void) {
        lock.lock()
        guard !executing, !stopping else { lock.unlock(); return }
        executing = true
        lock.unlock()
        perform(#selector(run(_:)), on: thread, with: Work(body), waitUntilDone: false)
    }

    @objc private func run(_ work: Work) {
        lock.lock()
        let shouldRun = !stopping
        lock.unlock()
        guard shouldRun else { return }
        work.body(self)
        lock.lock(); executing = false; lock.unlock()
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
        thread.cancel()
        phone?.delegate = nil
        phone?.disconnect()
        phone = nil
    }

    func connect(phoneID: String, generation: UUID) {
        phone?.delegate = nil
        phone?.disconnect()
        phone = nil
        self.generation = generation
        session.disconnected()
        guard let device = IOBluetoothDevice(addressString: phoneID), device.isPaired(), device.isHandsFreeAudioGateway else {
            emit("Selected phone is unavailable or does not advertise HFP.", completed: true); return
        }
        session.connected(phoneID: phoneID)
        phone = IOBluetoothHandsFreeDevice(device: device, delegate: self)
        guard let phone else { session.disconnected(); emit("Could not initialize Bluetooth calling.", completed: true); return }
        phone.connect()
    }

    func disconnect() {
        phone?.delegate = nil
        phone?.disconnect()
        phone = nil; pendingAction = nil; session.disconnected()
        emit("Bluetooth calling disconnected.", completed: true)
    }

    func perform(_ action: MacCallAction, context: MacCallContext) {
        guard let phone, phone.isConnected, session.begin(action, context: context) else {
            emit("Call changed; action ignored.", completed: true); return
        }
        pendingAction = action
        emit("Waiting for phone confirmation…")
        switch action {
        case .answer: phone.acceptCall(); phone.transferAudioToComputer()
        case .decline, .hangUp: phone.endCall()
        case .computerAudio:
            phone.transferAudioToComputer()
            if phone.isSCOConnected() {
                session.setSCO(true); pendingAction = nil
                emit("Bluetooth audio connected; two-way laptop audio has not been verified.", completed: true)
            }
        case .phoneAudio:
            phone.transferAudioToPhone()
            if !phone.isSCOConnected() { session.setSCO(false); pendingAction = nil; emit("Bluetooth audio disconnected; check the phone route.", completed: true) }
        case .toggleMute:
            phone.isInputMuted.toggle()
            session.setMuted(phone.isInputMuted)
            pendingAction = nil
            emit(session.muted ? "Mac HFP input muted." : "Mac HFP input unmuted.", completed: true)
        }
    }

    private func emit(_ message: String, completed: Bool = false) { onEvent?(generation, session, message, completed) }
    private func owns(_ device: IOBluetoothHandsFree?) -> Bool { device != nil && device === phone }

    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        guard owns(device) else { return }
        if status?.int32Value == 0 {
            emit("Phone connected. Waiting for calls.", completed: true)
            if phone?.indicator(IOBluetoothHandsFreeIndicatorCall) == 1 { session.setActive(true) }
            if phone?.indicator(IOBluetoothHandsFreeIndicatorCallSetup) == 1 { session.ringing(number: nil) }
            if session.context != nil { emit("Current phone call detected.") }
            phone?.currentCallList()
        } else {
            session.disconnected()
            emit("Bluetooth service connection failed (\(status?.intValue ?? -1)).", completed: true)
        }
    }
    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        guard owns(device) else { return }
        session.disconnected(); pendingAction = nil
        emit("Phone disconnected. Reconnect to enable calling.", completed: true)
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        guard owns(device) else { return }
        let success = status?.int32Value == 0
        session.setSCO(success)
        let completed = pendingAction?.completesOnSCO(connected: success) == true
        if completed { pendingAction = nil }
        emit(success ? "Bluetooth audio connected; two-way laptop audio has not been verified." : "Bluetooth audio connection failed. Use phone audio or reconnect.", completed: completed)
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        guard owns(device) else { return }
        session.setSCO(false)
        let completed = pendingAction?.completesOnSCO(connected: false) == true
        if completed { pendingAction = nil }
        emit("Bluetooth audio disconnected; check the phone audio route.", completed: completed)
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
            session.setupEnded()
            let completed = session.context == nil
            if completed { pendingAction = nil }
            emit(session.context == nil ? "Call ended." : "Call active.", completed: completed)
        }
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive active: NSNumber!) {
        guard owns(device) else { return }
        session.setActive(active?.boolValue == true)
        if active?.boolValue == true { session.setSCO(phone?.isSCOConnected() == true) }
        let completed = (pendingAction == .answer && active?.boolValue == true) ||
            ((pendingAction == .hangUp || pendingAction == .decline) && active?.boolValue == false)
        if completed { pendingAction = nil }
        emit(active?.boolValue == true ? "Call active; check laptop audio." : "Call ended.", completed: completed)
    }
    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall call: [AnyHashable: Any]!) {
        guard owns(device), let call,
              let status = call[IOBluetoothHandsFreeCallStatus] as? NSNumber else { return }
        session.observeCall(index: (call[IOBluetoothHandsFreeCallIndex] as? NSNumber)?.intValue, status: status.intValue)
        emit(session.hasWaitingCall ? "Multiple calls; manage calls on the phone." : "Phone call state received.")
    }
}

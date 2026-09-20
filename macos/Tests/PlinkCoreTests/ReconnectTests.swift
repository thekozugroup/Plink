import Darwin
import Foundation
import Testing
@testable import PlinkCore

@Test func reconnectNetworkFixturesUseProductionCandidatePolicy() throws {
    let data = try Data(contentsOf: reconnectSupplementalFixture("network-cases.json"))
    let fixture = try PlinkJSON.decoder().decode(NetworkFixture.self, from: data)
    #expect(fixture.cases.count == 28)
    for fixtureCase in fixture.cases {
        let accepted = ReconnectCandidatePolicy.candidate(
            endpoint: fixtureCase.endpoint,
            interface: fixtureCase.interface
        ) != nil
        #expect(accepted == fixtureCase.expectedMac, "\(fixtureCase.name)")
    }
}

@Test func reconnectEndpointVectorsUseProductionAuthenticationAndFilenameHelpers() throws {
    let data = try Data(contentsOf: reconnectSupplementalFixture("endpoint-store-vectors.json"))
    let fixture = try PlinkJSON.decoder().decode(EndpointFixture.self, from: data)
    #expect(fixture.vectors.count == 3)
    for vector in fixture.vectors {
        let key = try #require(Data(base64Encoded: vector.sessionKeyBase64))
        #expect(ReconnectEndpointStore.authenticationInput(for: vector.record).base64EncodedString() ==
            vector.signingInputBase64, "\(vector.name): signing input")
        #expect(ReconnectEndpointStore.authenticationTag(for: vector.record, sessionKey: key) ==
            vector.record.tag, "\(vector.name): tag")
        #expect(ReconnectEndpointStore.fileName(localID: vector.record.localID,
            peerID: vector.record.peerID, sessionKey: key) == vector.fileName, "\(vector.name): filename")
    }
}

@Test func reconnectEndpointCommitIsAuthenticatedAndStaleCommitCannotReplaceIt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ReconnectEndpointStore(directory: directory)
    let key = Data((0..<32).map { UInt8($0) })
    let proof = "ABEiM0RVZneImaq7zN3u_wARIjNEVWZ3iJmqu8zd7v8"
    let endpoint = try IPv4Endpoint("192.168.50.20:45731")
    let authority = ReconnectCommitAuthority()
    let committed = try store.commit(localID: "mac-É", peerID: "pixel-東京",
        sessionID: "00000000-0000-4000-8000-000000000001", endpoint: endpoint,
        proofID: proof, sessionKey: key, authority: authority)
    #expect(try store.load(localID: committed.localID, peerID: committed.peerID,
        sessionID: committed.sessionID, sessionKey: key) == committed)

    let cancelledAuthority = ReconnectCommitAuthority()
    cancelledAuthority.invalidate()
    #expect(throws: ReconnectEndpointStoreError.staleLifecycle) {
        _ = try store.commit(localID: committed.localID, peerID: committed.peerID,
            sessionID: committed.sessionID, endpoint: try IPv4Endpoint("192.168.50.21:45731"),
            proofID: proof, sessionKey: key, authority: cancelledAuthority)
    }
    #expect(try store.load(localID: committed.localID, peerID: committed.peerID,
        sessionID: committed.sessionID, sessionKey: key) == committed)
    let expiredAuthority = ReconnectCommitAuthority(deadline: ContinuousClock.now)
    #expect(throws: ReconnectEndpointStoreError.staleLifecycle) {
        _ = try store.commit(localID: committed.localID, peerID: committed.peerID,
            sessionID: committed.sessionID, endpoint: try IPv4Endpoint("192.168.50.22:45731"),
            proofID: proof, sessionKey: key, authority: expiredAuthority)
    }
    #expect(try store.load(localID: committed.localID, peerID: committed.peerID,
        sessionID: committed.sessionID, sessionKey: key) == committed)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let file = directory.appendingPathComponent(ReconnectEndpointStore.fileName(
        localID: committed.localID, peerID: committed.peerID, sessionKey: key))
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    var tampered = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    tampered["tag"] = "invalid"
    try JSONSerialization.data(withJSONObject: tampered).write(to: file, options: .atomic)
    #expect(try store.load(localID: committed.localID, peerID: committed.peerID,
        sessionID: committed.sessionID, sessionKey: key) == nil)
}

@Test func reconnectEndpointStoreRejectsInvalidUTF8ByteLength() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ReconnectEndpointStore(directory: directory)
    let overlongUnicodeID = String(repeating: "é", count: 65)
    #expect(overlongUnicodeID.count == 65)
    #expect(overlongUnicodeID.utf8.count == 130)
    #expect(throws: ReconnectEndpointStoreError.invalidRecord) {
        _ = try store.commit(localID: overlongUnicodeID, peerID: "pixel", sessionID: "session",
            endpoint: try IPv4Endpoint("192.168.50.20:45731"),
            proofID: "ABEiM0RVZneImaq7zN3u_wARIjNEVWZ3iJmqu8zd7v8",
            sessionKey: Data(repeating: 7, count: 32), authority: ReconnectCommitAuthority())
    }
}

@Test func pairWriteGateGrantsQueuedLeasesInFIFOOrder() async throws {
    let gate = PairWriteGate()
    let release = AsyncTestSignal()
    let order = AsyncTestOrder()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    let first = Task {
        try await gate.withWrite(deadline: deadline) {
            await order.append(1)
            await release.wait()
        }
    }
    while (await order.values).isEmpty { await Task.yield() }
    let second = Task { try await gate.withWrite(deadline: deadline) { await order.append(2) } }
    try await Task.sleep(for: .milliseconds(10))
    let third = Task { try await gate.withWrite(deadline: deadline) { await order.append(3) } }
    try await Task.sleep(for: .milliseconds(10))
    await release.signal()
    try await first.value
    try await second.value
    try await third.value
    #expect(await order.values == [1, 2, 3])
}

@Test func invalidatedPairLifetimeClosesAdmissionAndQueuedWriter() async throws {
    let lifetime = PairSessionLifetime(localID: "mac", peerID: "pixel", sessionID: "session",
        sessionKey: Data(repeating: 3, count: 32), stateStore: InMemoryFrameStateStore())
    let interface = ReconnectInterfaceSnapshot(name: "test", index: 7, localIPv4: "192.168.50.10",
        prefixLength: 24, up: true, loopback: false, pointToPoint: false, broadcast: true, vpn: false)
    let binding = VerifiedNetworkBinding(interface: interface, localIPv4: interface.localIPv4,
        peer: try IPv4Endpoint("192.168.50.20:45731"), localListenerPort: 45_731,
        peerListenerPort: 45_731)
    _ = try lifetime.openOrdinaryAdmission(binding: binding)
    let release = AsyncTestSignal()
    let entered = AsyncTestOrder()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    let active = Task {
        try await lifetime.writeGate.withWrite(deadline: deadline) {
            await entered.append(1)
            await release.wait()
        }
    }
    while (await entered.values).isEmpty { await Task.yield() }
    let queued = Task { try await lifetime.writeGate.withWrite(deadline: deadline) { 2 } }
    try await Task.sleep(for: .milliseconds(10))
    lifetime.invalidate()
    #expect(lifetime.ordinaryAdmission() == nil)
    do {
        _ = try await queued.value
        Issue.record("Queued lease unexpectedly survived lifetime invalidation")
    } catch {
        #expect(error as? ReconnectSessionError == .cancelled)
    }
    await release.signal()
    try await active.value
}

@Test func oldBoundClientCannotReactivateAfterSameBindingIsReproved() async throws {
    let lifetime = PairSessionLifetime(localID: "mac", peerID: "pixel", sessionID: "session",
        sessionKey: Data(repeating: 4, count: 32), stateStore: InMemoryFrameStateStore())
    let interface = ReconnectInterfaceSnapshot(name: "test", index: 7, localIPv4: "192.168.50.10",
        prefixLength: 24, up: true, loopback: false, pointToPoint: false, broadcast: true, vpn: false)
    let binding = VerifiedNetworkBinding(interface: interface, localIPv4: interface.localIPv4,
        peer: try IPv4Endpoint("192.168.50.20:45731"), localListenerPort: 45_731,
        peerListenerPort: 45_731)
    let oldGeneration = try lifetime.openOrdinaryAdmission(binding: binding)
    let oldClient = BoundSecureNetworkPlinkClient(lifetime: lifetime, binding: binding,
        generation: oldGeneration)
    lifetime.closeOrdinaryAdmission()
    let newGeneration = try lifetime.openOrdinaryAdmission(binding: binding)
    #expect(newGeneration != oldGeneration)
    let envelope = PlinkEnvelope(id: UUID().uuidString.lowercased(), type: .deviceStatus, sentAt: .now,
        sourceDeviceId: "mac", targetDeviceId: "pixel", payload: ["batteryLevel": .int(53)])
    await #expect(throws: ReconnectSessionError.staleLifetime) {
        try await oldClient.send(envelope, timeout: 0.1)
    }
}

@Test func acceptedSocketLeaseCannotRecaptureAfterReproof() throws {
    let lifetime = PairSessionLifetime(localID: "mac", peerID: "pixel", sessionID: "session",
        sessionKey: Data(repeating: 11, count: 32), stateStore: InMemoryFrameStateStore(),
        validation: ReconnectValidationPolicy(allowedPorts: [45_731], allowsLoopback: true))
    let interface = ReconnectInterfaceSnapshot(name: "lo0", index: 1, localIPv4: "127.0.0.1",
        prefixLength: 8, up: true, loopback: true, pointToPoint: false, broadcast: true, vpn: false)
    let binding = VerifiedNetworkBinding(interface: interface, localIPv4: interface.localIPv4,
        peer: try IPv4Endpoint("127.0.0.1:45731"), localListenerPort: 45_731,
        peerListenerPort: 45_731)
    let acceptedGeneration = try lifetime.openOrdinaryAdmission(binding: binding)
    let listener = try nonblockingLoopbackListener()
    defer { Darwin.close(listener.descriptor) }
    let peer = try connectLoopback(port: listener.port)
    defer { Darwin.close(peer) }
    var ready = pollfd(fd: listener.descriptor, events: Int16(POLLIN), revents: 0)
    let readyCount = Darwin.poll(&ready, 1, 1_000)
    try #require(readyCount > 0 && ready.revents & Int16(POLLIN) != 0)
    guard let accepted = try lifetime.acceptNonblocking(listenerDescriptor: listener.descriptor) else {
        Issue.record("Queued connection was not accepted")
        return
    }
    defer { Darwin.close(accepted.descriptor) }
    guard let lease = accepted.admission else {
        Issue.record("Accepted connection did not capture ordinary admission")
        return
    }
    lifetime.closeOrdinaryAdmission()
    let replacementGeneration = try lifetime.openOrdinaryAdmission(binding: binding)

    #expect(lease.generation == acceptedGeneration)
    #expect(replacementGeneration != acceptedGeneration)
    #expect(throws: ReconnectSessionError.staleLifetime) {
        try lifetime.requireCurrent(binding: lease.binding, generation: lease.generation)
    }
}

@Test func cancellingStalledReconnectReceiveJoinsOwnedIO() async throws {
    let (socket, peer) = try reconnectSocketPair()
    defer { socket.close(); Darwin.close(peer) }
    let lifetime = reconnectTestLifetime()
    let receive = Task {
        try await socket.receive(lifetime: lifetime, timeout: 5, maxWireBytes: 4_096)
    }
    try await Task.sleep(for: .milliseconds(20))
    let cancelledAt = ContinuousClock.now
    receive.cancel()
    do {
        _ = try await receive.value
        Issue.record("Cancelled receive unexpectedly completed")
    } catch {
        #expect(error as? ReconnectSessionError == .cancelled)
    }
    #expect(cancelledAt.duration(to: ContinuousClock.now) < .seconds(1))
}

@Test func closingSocketDuringReceiveCannotCloseReusedDescriptor() async throws {
    let (socket, peer) = try reconnectSocketPair()
    defer { Darwin.close(peer) }
    let receive = Task {
        try await socket.receive(lifetime: reconnectTestLifetime(), timeout: 5, maxWireBytes: 4_096)
    }
    try await Task.sleep(for: .milliseconds(20))
    socket.close()
    let replacement = Darwin.open("/dev/null", O_RDONLY)
    defer { if replacement >= 0 { Darwin.close(replacement) } }
    #expect(replacement >= 0)
    do { _ = try await receive.value } catch { }
    #expect(fcntl(replacement, F_GETFD) >= 0)
}

@Test func reconnectReceiveUsesOneDeadlineAcrossHeaderAndBody() async throws {
    let (socket, peer) = try reconnectSocketPair()
    defer { socket.close(); Darwin.close(peer) }
    let started = ContinuousClock.now
    let receive = Task {
        try await socket.receive(lifetime: reconnectTestLifetime(), timeout: 0.25, maxWireBytes: 4_096)
    }
    try await Task.sleep(for: .milliseconds(180))
    let header: [UInt8] = [0, 0, 0, 10]
    _ = header.withUnsafeBytes { Darwin.send(peer, $0.baseAddress!, $0.count, MSG_DONTWAIT) }
    do {
        _ = try await receive.value
        Issue.record("Partial frame unexpectedly completed")
    } catch {
        #expect(error as? ReconnectSessionError == .timedOut)
    }
    #expect(started.duration(to: ContinuousClock.now) < .milliseconds(360))
}

@Test func reconnectReceiveRejectsCompletionAfterReplayPersistenceDeadline() async throws {
    let (socket, peer) = try reconnectSocketPair()
    defer { socket.close(); Darwin.close(peer) }
    let state = BlockingAcceptStore()
    let lifetime = PairSessionLifetime(localID: "mac", peerID: "pixel", sessionID: "session",
        sessionKey: Data(repeating: 9, count: 32), stateStore: state,
        validation: ReconnectValidationPolicy(allowedPorts: [45_731], allowsLoopback: true))
    let envelope = PlinkEnvelope(id: UUID().uuidString.lowercased(), type: .deviceStatus, sentAt: .now,
        sourceDeviceId: "pixel", targetDeviceId: "mac", payload: ["batteryLevel": .int(53)])
    let frame = try lifetime.codec.seal(envelope, sequence: 1)
    let framed = try LengthPrefixedFrameCodec.encode(PlinkJSON.encoder().encode(frame))
    let receive = Task {
        try await socket.receive(lifetime: lifetime,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(50)), maxWireBytes: 4_096)
    }
    try sendTestBytes(framed, descriptor: peer)
    let startDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !state.acceptStarted, ContinuousClock.now < startDeadline { await Task.yield() }
    guard state.acceptStarted else {
        receive.cancel()
        state.release()
        Issue.record("Replay persistence was not reached")
        return
    }
    try await Task.sleep(for: .milliseconds(80))
    state.release()
    await #expect(throws: ReconnectSessionError.timedOut) { try await receive.value }
}

@Test func reconnectListenerStopJoinsAuthenticatedReplayPersistence() async throws {
    let port = try unusedLoopbackPort()
    let state = BlockingAcceptStore()
    let registration = BlockingRegistrationLatch()
    let lifetime = PairSessionLifetime(localID: "mac", peerID: "pixel", sessionID: "session",
        sessionKey: Data(repeating: 10, count: 32), stateStore: state,
        validation: ReconnectValidationPolicy(allowedPorts: [port], allowsLoopback: true))
    let listener = ReconnectListener(port: port, bindAddress: "127.0.0.1", lifetime: lifetime,
        processingRegistrationHook: { registration.arriveAndWait() }) { _, _ in }
    try listener.start()
    let peer = try connectLoopback(port: port)
    defer { Darwin.close(peer); lifetime.invalidate() }
    let envelope = PlinkEnvelope(id: UUID().uuidString.lowercased(), type: .deviceStatus, sentAt: .now,
        sourceDeviceId: "pixel", targetDeviceId: "mac", payload: ["batteryLevel": .int(53)])
    let frame = try lifetime.codec.seal(envelope, sequence: 1)
    try sendTestBytes(try LengthPrefixedFrameCodec.encode(PlinkJSON.encoder().encode(frame)), descriptor: peer)
    let startDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while (!state.acceptStarted || !registration.isEntered), ContinuousClock.now < startDeadline {
        await Task.yield()
    }
    guard state.acceptStarted, registration.isEntered else {
        registration.release()
        state.release()
        listener.stop()
        Issue.record("Listener replay persistence and registration latch were not reached")
        return
    }

    let stopped = LockedTestFlag()
    let stopCalled = LockedTestFlag()
    let stopping = Task.detached {
        stopCalled.set()
        listener.stop()
        stopped.set()
    }
    while !stopCalled.value { await Task.yield() }
    registration.release()
    var ready = pollfd(fd: peer, events: Int16(POLLIN | POLLHUP), revents: 0)
    #expect(Darwin.poll(&ready, 1, 1_000) > 0)
    var byte: UInt8 = 0
    #expect(Darwin.recv(peer, &byte, 1, MSG_DONTWAIT) == 0)
    #expect(!stopped.value)
    state.release()
    await stopping.value
    #expect(stopped.value)
    #expect(state.acceptObservedCancellation)
}

@Test func candidateDeadlineClosesReverseChannelWhileBlockedCommitJoins() async throws {
    let phoneListener = try nonblockingLoopbackListener()
    defer { Darwin.close(phoneListener.descriptor) }
    let macPort = try unusedLoopbackPort()
    let loopbackIndex = "lo0".withCString { if_nametoindex($0) }
    let interface = ReconnectInterfaceSnapshot(name: "lo0", index: loopbackIndex,
        localIPv4: "127.0.0.1", prefixLength: 8, up: true, loopback: true,
        pointToPoint: false, broadcast: true, vpn: false)
    let validation = ReconnectValidationPolicy(allowedPorts: [phoneListener.port, macPort], allowsLoopback: true)
    let key = Data(repeating: 12, count: 32)
    let macLifetime = PairSessionLifetime(localID: "mac", peerID: "pixel", sessionID: "session",
        sessionKey: key, stateStore: InMemoryFrameStateStore(), validation: validation)
    let phoneLifetime = PairSessionLifetime(localID: "pixel", peerID: "mac", sessionID: "session",
        sessionKey: key, stateStore: InMemoryFrameStateStore(), validation: validation)
    let listener = ReconnectListener(port: macPort, bindAddress: "127.0.0.1", lifetime: macLifetime) { _, _ in }
    try listener.start()
    let committer = BlockingEndpointCommitter()
    let expired = LockedTestFlag()
    let overallDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    let authority = ReconnectCommitAuthority(deadline: overallDeadline)
    let initiator = ReconnectInitiator(lifetime: macLifetime, listener: listener,
        commitAuthority: authority, endpointCommitter: committer, listenerPort: macPort,
        onCandidateExpired: { expired.set() })
    let candidate = ReconnectCandidate(endpoint: try IPv4Endpoint(address: "127.0.0.1",
        port: phoneListener.port), interface: interface)
    let candidateDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    let completed = LockedTestFlag()
    defer {
        committer.release()
        listener.stop()
        macLifetime.invalidate()
        phoneLifetime.invalidate()
    }

    let phone = Task.detached { () throws -> ContinuousClock.Instant in
        let outbound = try acceptReconnectSocket(listenerDescriptor: phoneListener.descriptor)
        defer { outbound.close() }
        let hello = try ReconnectMessage(try await outbound.receive(lifetime: phoneLifetime,
            deadline: candidateDeadline), validation: validation)
        guard hello.type == .reconnectHello else { throw ReconnectTestError.unexpectedPhase }
        let p = canonicalTestNonce(byte: 0x70)
        try await sendReconnectControl(type: .reconnectChallenge, m: hello.m, p: p, r: nil,
            mac: hello.mac, phone: hello.phone, source: "pixel", target: "mac",
            socket: outbound, lifetime: phoneLifetime, deadline: candidateDeadline)
        let proof = try ReconnectMessage(try await outbound.receive(lifetime: phoneLifetime,
            deadline: candidateDeadline), validation: validation)
        guard proof.type == .reconnectProof, proof.m == hello.m, proof.p == p else {
            throw ReconnectTestError.unexpectedPhase
        }
        outbound.close()

        let reverseCandidate = ReconnectCandidate(endpoint: hello.mac, interface: interface)
        let reverse = try await ReconnectSocket.connect(candidate: reverseCandidate, deadline: candidateDeadline)
        defer { reverse.close() }
        let r = canonicalTestNonce(byte: 0x72)
        try await sendReconnectControl(type: .reconnectReverse, m: hello.m, p: p, r: r,
            mac: hello.mac, phone: hello.phone, source: "pixel", target: "mac",
            socket: reverse, lifetime: phoneLifetime, deadline: candidateDeadline)
        let reverseProof = try ReconnectMessage(try await reverse.receive(lifetime: phoneLifetime,
            deadline: candidateDeadline), validation: validation)
        guard reverseProof.type == .reconnectReverseProof, reverseProof.r == r else {
            throw ReconnectTestError.unexpectedPhase
        }
        try await sendReconnectControl(type: .reconnectReady, m: hello.m, p: p, r: r,
            mac: hello.mac, phone: hello.phone, source: "pixel", target: "mac",
            socket: reverse, lifetime: phoneLifetime, deadline: candidateDeadline)
        do {
            _ = try await reverse.receive(lifetime: phoneLifetime,
                deadline: candidateDeadline.advanced(by: .seconds(1)))
            throw ReconnectTestError.unexpectedCommit
        } catch let error as ReconnectTestError {
            throw error
        } catch {
            return ContinuousClock.now
        }
    }
    let attempt = Task {
        defer { completed.set() }
        return try await initiator.attempt(candidate: candidate, deadline: candidateDeadline)
    }
    let commitStartDeadline = candidateDeadline
    while !committer.commitStarted, ContinuousClock.now < commitStartDeadline { await Task.yield() }
    try #require(committer.commitStarted)

    let closedAt = try await phone.value
    #expect(closedAt >= candidateDeadline)
    #expect(candidateDeadline.duration(to: closedAt) < .seconds(1))
    let expirationCallbackDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !expired.value, ContinuousClock.now < expirationCallbackDeadline { await Task.yield() }
    #expect(expired.value)
    #expect(!completed.value)
    #expect(!committer.didCommit)
    committer.release()
    await #expect(throws: ReconnectSessionError.timedOut) { try await attempt.value }
    #expect(completed.value)
    #expect(!committer.didCommit)
}

@Test func expiredSendBurnsSequenceButWritesNoBytes() async throws {
    for attempt in 0..<3 {
        let (socket, peer) = try reconnectSocketPair()
        defer { socket.close(); Darwin.close(peer) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let state = SlowReservationStore(deadline: deadline)
        let lifetime = PairSessionLifetime(localID: "mac", peerID: "pixel", sessionID: "session",
            sessionKey: Data(repeating: 5, count: 32), stateStore: state)
        let envelope = PlinkEnvelope(id: UUID().uuidString.lowercased(), type: .deviceStatus, sentAt: .now,
            sourceDeviceId: "mac", targetDeviceId: "pixel", payload: ["batteryLevel": .int(53)])
        await #expect(throws: ReconnectSessionError.timedOut) {
            try await socket.send(envelope, lifetime: lifetime, deadline: deadline)
        }
        var byte: UInt8 = 0
        let received = Darwin.recv(peer, &byte, 1, MSG_DONTWAIT)
        let receiveError = errno
        #expect(received <= 0)
        if received < 0 {
            #expect(receiveError == EAGAIN || receiveError == EWOULDBLOCK)
        }
        // Expiry before reservation is valid, but does not exercise the post-reservation guard.
        // Retry only that setup outcome; the final attempt must exercise sequence burning.
        if state.reservations == 0 && attempt < 2 { continue }
        #expect(state.reservations == 1)
        return
    }
}

@Test func reconnectWriteTimesOutWhenPeerStopsReading() async throws {
    let (socket, peer) = try reconnectSocketPair(sendBuffer: 1_024)
    defer { socket.close(); Darwin.close(peer) }
    let lifetime = reconnectTestLifetime()
    let envelope = PlinkEnvelope(id: UUID().uuidString.lowercased(), type: .clipboardUpdated, sentAt: .now,
        sourceDeviceId: "mac", targetDeviceId: "pixel",
        payload: ["text": .string(String(repeating: "x", count: 60_000))])
    await #expect(throws: ReconnectSessionError.timedOut) {
        try await socket.send(envelope, lifetime: lifetime, timeout: 0.1)
    }
}

private struct NetworkFixture: Decodable {
    let cases: [NetworkCase]
}

private struct NetworkCase: Decodable {
    let endpoint: String
    let interface: ReconnectInterfaceSnapshot
    let name: String
    let expectedMac: Bool
}

private struct EndpointFixture: Decodable {
    let vectors: [EndpointVector]
}

private struct EndpointVector: Decodable {
    let name: String
    let sessionKeyBase64: String
    let record: ReconnectEndpointRecord
    let signingInputBase64: String
    let fileName: String
}

private enum ReconnectTestError: Error {
    case unexpectedPhase
    case unexpectedCommit
}

private func canonicalTestNonce(byte: UInt8) -> String {
    Data(repeating: byte, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private final class BlockingEndpointCommitter: ReconnectEndpointCommitting, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var committed = false

    func commit(
        localID: String,
        peerID: String,
        sessionID: String,
        endpoint: IPv4Endpoint,
        proofID: String,
        sessionKey: Data,
        authority: ReconnectCommitAuthority,
        candidateAuthority: ReconnectCandidateCommitAuthority?,
        deadline: ContinuousClock.Instant?
    ) throws -> ReconnectEndpointRecord {
        condition.lock()
        started = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        guard let candidateAuthority else { throw ReconnectEndpointStoreError.staleLifecycle }
        return try authority.withCurrent(candidate: candidateAuthority, deadline: deadline) {
            condition.lock()
            committed = true
            condition.unlock()
            return ReconnectEndpointRecord(localID: localID, peerID: peerID, sessionID: sessionID,
                endpoint: endpoint.description, proofID: proofID, tag: "")
        }
    }

    var commitStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    var didCommit: Bool {
        condition.lock()
        defer { condition.unlock() }
        return committed
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private func acceptReconnectSocket(listenerDescriptor: Int32) throws -> ReconnectSocket {
    var ready = pollfd(fd: listenerDescriptor, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&ready, 1, 1_000) > 0, ready.revents & Int16(POLLIN) != 0 else {
        throw ReconnectSessionError.timedOut
    }
    let descriptor = Darwin.accept(listenerDescriptor, nil, nil)
    guard descriptor >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
    return try ReconnectSocket.accepted(descriptor: descriptor)
}

private func sendReconnectControl(
    type: EventType,
    m: String,
    p: String?,
    r: String?,
    mac: IPv4Endpoint,
    phone: IPv4Endpoint,
    source: String,
    target: String,
    socket: ReconnectSocket,
    lifetime: PairSessionLifetime,
    deadline: ContinuousClock.Instant
) async throws {
    var payload: [String: PayloadValue] = [
        "v": .int(1), "m": .string(m), "mac": .string(mac.description),
        "phone": .string(phone.description)
    ]
    if let p { payload["p"] = .string(p) }
    if let r { payload["r"] = .string(r) }
    let envelope = PlinkEnvelope(id: UUID().uuidString.lowercased(), type: type, sentAt: .now,
        sourceDeviceId: source, targetDeviceId: target, payload: payload)
    try await lifetime.writeGate.withWrite(deadline: deadline) {
        try await socket.send(envelope, lifetime: lifetime, deadline: deadline)
    }
}

private actor AsyncTestSignal {
    private var signalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func signal() {
        signalled = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor AsyncTestOrder {
    private var stored: [Int] = []
    func append(_ value: Int) { stored.append(value) }
    var values: [Int] { stored }
}

private final class SlowReservationStore: FrameStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private var count: Int64 = 0

    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

    func reserveSequence(scope: String) throws -> Int64 {
        let sequence = lock.withLock {
            count += 1
            return count
        }
        // Expire the actual send deadline only after its sequence has been reserved.
        while ContinuousClock.now < deadline { usleep(1_000) }
        return sequence
    }

    func accept(scope: String, sequence: Int64, nonce: String) throws {}
    var reservations: Int64 { lock.withLock { count } }
}

private final class BlockingAcceptStore: FrameStateStoring, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var cancelled = false

    func reserveSequence(scope: String) throws -> Int64 { 1 }

    func accept(scope: String, sequence: Int64, nonce: String) throws {
        condition.lock()
        started = true
        condition.broadcast()
        while !released { condition.wait() }
        cancelled = Task.isCancelled
        condition.unlock()
    }

    var acceptStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    var acceptObservedCancellation: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class BlockingRegistrationLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func arriveAndWait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    var isEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

private func reconnectTestLifetime() -> PairSessionLifetime {
    PairSessionLifetime(localID: "mac", peerID: "pixel", sessionID: "session",
        sessionKey: Data(repeating: 6, count: 32), stateStore: InMemoryFrameStateStore(),
        validation: ReconnectValidationPolicy(allowedPorts: [45_731], allowsLoopback: true))
}

private func reconnectSocketPair(sendBuffer: Int32? = nil) throws -> (ReconnectSocket, Int32) {
    let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
    defer { Darwin.close(listener) }
    var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
        sin_family: sa_family_t(AF_INET), sin_port: 0,
        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, Darwin.listen(listener, 1) == 0 else {
        throw ReconnectSessionError.socketFailure(errno)
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    let peer = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard peer >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(peer, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        Darwin.close(peer)
        throw ReconnectSessionError.socketFailure(errno)
    }
    let accepted = Darwin.accept(listener, nil, nil)
    guard accepted >= 0 else {
        Darwin.close(peer)
        throw ReconnectSessionError.socketFailure(errno)
    }
    if var sendBuffer {
        guard setsockopt(accepted, SOL_SOCKET, SO_SNDBUF, &sendBuffer,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(accepted)
            Darwin.close(peer)
            throw ReconnectSessionError.socketFailure(errno)
        }
    }
    let flags = fcntl(peer, F_GETFL, 0)
    _ = fcntl(peer, F_SETFL, flags | O_NONBLOCK)
    do { return (try ReconnectSocket.accepted(descriptor: accepted), peer) }
    catch { Darwin.close(peer); throw error }
}

private func unusedLoopbackPort() throws -> UInt16 {
    let listener = try nonblockingLoopbackListener()
    Darwin.close(listener.descriptor)
    return listener.port
}

private func nonblockingLoopbackListener() throws -> (descriptor: Int32, port: UInt16) {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
    var reuse: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
        sin_family: sa_family_t(AF_INET), sin_port: 0,
        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else {
        let failure = errno
        Darwin.close(descriptor)
        throw ReconnectSessionError.socketFailure(failure)
    }
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
          Darwin.listen(descriptor, 1) == 0 else {
        let failure = errno
        Darwin.close(descriptor)
        throw ReconnectSessionError.socketFailure(failure)
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard named == 0 else {
        let failure = errno
        Darwin.close(descriptor)
        throw ReconnectSessionError.socketFailure(failure)
    }
    return (descriptor, UInt16(bigEndian: address.sin_port))
}

private func connectLoopback(port: UInt16) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ReconnectSessionError.socketFailure(errno) }
    var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
        sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        let failure = errno
        Darwin.close(descriptor)
        throw ReconnectSessionError.socketFailure(failure)
    }
    return descriptor
}

private func sendTestBytes(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var sent = 0
        while sent < bytes.count {
            let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
            guard count > 0 else { throw ReconnectSessionError.socketFailure(errno) }
            sent += count
        }
    }
}

private func reconnectSupplementalFixture(_ name: String) throws -> URL {
    let path = "shared/protocol/v1/reconnect/\(name)"
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        let candidate = directory.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

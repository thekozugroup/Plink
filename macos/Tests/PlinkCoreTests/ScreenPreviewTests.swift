import Foundation
import PlinkCore
import Testing

private let screenLocalDeviceID = "test-mac"
private let screenPeerDeviceID = "test-pixel"
private let fixedScreenStreamID = "22222222-2222-4222-8222-222222222222"

@Test func screenPreviewSharedContractVectors() async throws {
    let fixtures = try loadScreenFixtures()
    let decoder = ScreenFrameDecoder()

    for item in fixtures.cases {
        let raw: Data
        if let rawEnvelope = item.rawEnvelope {
            raw = Data(rawEnvelope.utf8)
        } else {
            raw = try PlinkJSON.encoder(sortedKeys: true).encode(try #require(item.envelope))
        }

        var accepted = false
        do {
            let envelope = try PlinkEnvelope.decode(raw)
            try PayloadPolicy.validate(envelope)
            if envelope.type == .screenFrame {
                let frame = try await decoder.decode(envelope)
                #expect(frame.image.width == frame.width, "\(item.name)")
                #expect(frame.image.height == frame.height, "\(item.name)")
            }
            accepted = true
        } catch {}
        #expect(accepted == item.valid, "\(item.name)")
    }
}

@Test func deterministicEncryptedScreenVectorMatchesProductionCodec() throws {
    let vector = try #require(loadScreenFixtures().encryptedVectors.first {
        $0.name == "fixed encrypted request"
    })
    let sessionKey = try #require(Data(base64Encoded: vector.sessionKeyBase64))
    let iv = try #require(Data(base64Encoded: vector.ivBase64))
    let plaintext = Data(vector.plaintext.utf8)
    let expected = try PlinkEnvelope.decode(plaintext)
    let codec = EncryptedFrameCodec(sessionKey: sessionKey)
    let wire = try PlinkJSON.encoder(sortedKeys: true).encode(vector.frame)

    let opened = try codec.open(
        vector.frame,
        now: vector.frame.issuedAt,
        expectedSourceDeviceId: vector.frame.sourceDeviceId,
        expectedTargetDeviceId: vector.frame.targetDeviceId,
        wireBytes: wire.count
    )
    #expect(opened == expected)

    let resealed = try codec.seal(
        expected,
        sequence: vector.sequence,
        nonce: vector.nonce,
        issuedAt: vector.frame.issuedAt,
        iv: iv
    )
    #expect(resealed == vector.frame)
}

@Test func authenticatedMalformedScreenVectorsAreSanitizedAfterReplayAcceptance() throws {
    let vectors = try loadScreenFixtures().encryptedVectors.filter { $0.expectedError != nil }
    #expect(vectors.count == 3)

    for vector in vectors {
        let sessionKey = try #require(Data(base64Encoded: vector.sessionKeyBase64))
        let codec = EncryptedFrameCodec(sessionKey: sessionKey)
        let replay = ReplayProtector(maxClockSkew: 300)
        let wire = try PlinkJSON.encoder(sortedKeys: true).encode(vector.frame)

        let firstError = caughtError {
            try codec.open(
                vector.frame,
                replayProtector: replay,
                now: vector.frame.issuedAt,
                expectedSourceDeviceId: vector.frame.sourceDeviceId,
                expectedTargetDeviceId: vector.frame.targetDeviceId,
                wireBytes: wire.count
            )
        }
        let rejection = try #require(firstError as? AuthenticatedScreenProtocolRejection)
        #expect(rejection.peerDeviceID == vector.frame.sourceDeviceId, "\(vector.name)")
        #expect(rejection.requestID == vector.expectedRequestID, "\(vector.name)")
        #expect(rejection.streamID == vector.expectedStreamID, "\(vector.name)")
        #expect(rejection.reason == .protocolError, "\(vector.name)")

        let replayError = caughtError {
            try codec.open(
                vector.frame,
                replayProtector: replay,
                now: vector.frame.issuedAt,
                expectedSourceDeviceId: vector.frame.sourceDeviceId,
                expectedTargetDeviceId: vector.frame.targetDeviceId,
                wireBytes: wire.count
            )
        }
        #expect(replayError as? PayloadPolicyError == .replayDetected, "\(vector.name)")
    }
}

@Test func untrustedOrStaleMalformedFramesNeverBecomeScreenRejections() throws {
    let vector = try #require(loadScreenFixtures().encryptedVectors.first {
        $0.name == "fixed authenticated decimal index rejection"
    })
    let sessionKey = try #require(Data(base64Encoded: vector.sessionKeyBase64))
    let wire = try PlinkJSON.encoder(sortedKeys: true).encode(vector.frame)

    let wrongKeyError = caughtError {
        try EncryptedFrameCodec(sessionKey: Data(repeating: 0xff, count: 32)).open(
            vector.frame,
            replayProtector: ReplayProtector(),
            now: vector.frame.issuedAt,
            wireBytes: wire.count
        )
    }
    #expect(!(wrongKeyError is AuthenticatedScreenProtocolRejection))
    #expect(wrongKeyError as? PayloadPolicyError == .invalidSignature)

    let misroutedError = caughtError {
        try EncryptedFrameCodec(sessionKey: sessionKey).open(
            vector.frame,
            replayProtector: ReplayProtector(),
            now: vector.frame.issuedAt,
            expectedSourceDeviceId: "another-peer",
            expectedTargetDeviceId: vector.frame.targetDeviceId,
            wireBytes: wire.count
        )
    }
    #expect(!(misroutedError is AuthenticatedScreenProtocolRejection))
    #expect(misroutedError as? PayloadPolicyError == .deviceMismatch)

    let staleError = caughtError {
        try EncryptedFrameCodec(sessionKey: sessionKey).open(
            vector.frame,
            replayProtector: ReplayProtector(),
            now: vector.frame.issuedAt.addingTimeInterval(301),
            expectedSourceDeviceId: vector.frame.sourceDeviceId,
            expectedTargetDeviceId: vector.frame.targetDeviceId,
            wireBytes: wire.count
        )
    }
    #expect(!(staleError is AuthenticatedScreenProtocolRejection))
    #expect(staleError as? PayloadPolicyError == .staleFrame)
}

@Test func screenControlLimitUsesOriginalPlaintextBytes() throws {
    let request = ScreenPreviewMessage.request(
        requestID: "11111111-1111-4111-8111-111111111111"
    ).envelope(
        sourceDeviceID: screenLocalDeviceID,
        targetDeviceID: screenPeerDeviceID,
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        sentAt: Date(timeIntervalSince1970: 1_758_326_400)
    )
    let compact = try PlinkJSON.encoder(sortedKeys: true).encode(request)
    #expect(compact.count < ScreenPreviewProtocol.maxControlEnvelopeBytes)

    let exact = try paddedJSONObject(compact, byteCount: ScreenPreviewProtocol.maxControlEnvelopeBytes)
    let accepted = try PlinkEnvelope.decode(exact)
    try PayloadPolicy.validate(accepted)

    let oversized = try paddedJSONObject(compact, byteCount: ScreenPreviewProtocol.maxControlEnvelopeBytes + 1)
    #expect(caughtError { try PlinkEnvelope.decode(oversized) } != nil)

    let frame = try fixtureFrameEnvelope()
    let compactFrame = try PlinkJSON.encoder(sortedKeys: true).encode(frame)
    let paddedFrame = try paddedJSONObject(compactFrame, byteCount: 3_000)
    #expect(try PlinkEnvelope.decode(paddedFrame).type == .screenFrame)
}

@Test func productionDecoderRejectsNonFrameInputWithoutAllocation() async throws {
    let decoder = ScreenFrameDecoder()
    let ordinary = PlinkEnvelope(
        id: "ordinary",
        type: .deviceStatus,
        sentAt: .now,
        sourceDeviceId: screenPeerDeviceID,
        targetDeviceId: screenLocalDeviceID,
        payload: [:]
    )
    let control = ScreenPreviewMessage.request(
        requestID: "11111111-1111-4111-8111-111111111111"
    ).envelope(sourceDeviceID: screenLocalDeviceID, targetDeviceID: screenPeerDeviceID)

    let ordinaryError = await caughtError { try await decoder.decode(ordinary) }
    let controlError = await caughtError { try await decoder.decode(control) }
    #expect(ordinaryError as? PayloadPolicyError == .malformedFrame)
    #expect(controlError as? PayloadPolicyError == .malformedFrame)
}

@Test func productionDecoderRejectsMalformedAndUnsupportedImages() throws {
    let fixtures = try loadScreenFixtures()
    #expect(fixtures.decoderInvalidCases.count >= 6)
    for item in fixtures.decoderInvalidCases {
        let bytes = try #require(Data(base64Encoded: item.data))
        let error = caughtError {
            try ScreenFrameDecoder.decodeJPEG(bytes, width: item.width, height: item.height)
        }
        #expect(error as? PayloadPolicyError == .malformedFrame, "\(item.name)")
    }
}

@Test func screenSessionUsesProductionDecoderAndPullCadence() async throws {
    let startTime = ContinuousClock.now
    var session = ScreenPreviewSession(binding: ScreenPreviewBinding(
        localDeviceID: screenLocalDeviceID,
        peerDeviceID: screenPeerDeviceID
    ))
    let start = session.start(now: startTime)
    let requestID = try requestID(from: start)

    let started = ScreenPreviewMessage.started(
        requestID: requestID,
        streamID: fixedScreenStreamID
    ).envelope(sourceDeviceID: screenPeerDeviceID, targetDeviceID: screenLocalDeviceID)
    let firstPull = try session.receive(started, now: startTime.advanced(by: .milliseconds(10)))
    try expectPull(firstPull, requestID: requestID, streamID: fixedScreenStreamID, index: 1)

    let jpeg = try fixtureJPEG()
    let frameEnvelope = ScreenPreviewMessage.frame(ScreenFramePayload(
        requestID: requestID,
        streamID: fixedScreenStreamID,
        index: 1,
        width: 2,
        height: 2,
        jpegData: jpeg
    )).envelope(sourceDeviceID: screenPeerDeviceID, targetDeviceID: screenLocalDeviceID)
    let pending = try session.receive(frameEnvelope, now: startTime.advanced(by: .milliseconds(20)))
    let ticket = try #require(pending.frameTicket)
    let decoded = try await ScreenFrameDecoder().decode(try #require(pending.frameEnvelope))
    let presentedAt = startTime.advanced(by: .milliseconds(30))
    let presented = session.completePresentation(decoded, ticket: ticket, now: presentedAt)
    #expect(!presented.ended)
    #expect(session.snapshot(now: presentedAt).hasPresentedFrame)

    let secondPull = session.wake(now: presentedAt.advanced(by: .milliseconds(500)))
    try expectPull(secondPull, requestID: requestID, streamID: fixedScreenStreamID, index: 2)

    let stopped = session.stop(reason: .hidden)
    #expect(stopped.ended)
    #expect(stopped.outgoing.count == 1)
    #expect(session.phase == .stopped(.hidden))
}

@Test func preframeIdleDoesNotRenewFirstFrameLease() throws {
    let startTime = ContinuousClock.now
    var session = ScreenPreviewSession(binding: ScreenPreviewBinding(
        localDeviceID: screenLocalDeviceID,
        peerDeviceID: screenPeerDeviceID
    ))
    let requestID = try requestID(from: session.start(now: startTime))
    let started = ScreenPreviewMessage.started(requestID: requestID, streamID: fixedScreenStreamID)
        .envelope(sourceDeviceID: screenPeerDeviceID, targetDeviceID: screenLocalDeviceID)
    _ = try session.receive(started, now: startTime)

    let idle = ScreenPreviewMessage.idle(
        requestID: requestID,
        streamID: fixedScreenStreamID,
        index: 1,
        reason: .noNewFrame
    ).envelope(sourceDeviceID: screenPeerDeviceID, targetDeviceID: screenLocalDeviceID)
    _ = try session.receive(idle, now: startTime.advanced(by: .seconds(1)))
    let secondPull = session.wake(now: startTime.advanced(by: .milliseconds(1_500)))
    try expectPull(secondPull, requestID: requestID, streamID: fixedScreenStreamID, index: 2)

    let timedOut = session.wake(now: startTime.advanced(by: .seconds(5)))
    #expect(timedOut.ended)
    #expect(session.phase == .stopped(.timeout))
}

@Test func threeOversizeResponsesStopCapture() throws {
    let startTime = ContinuousClock.now
    var session = ScreenPreviewSession(binding: ScreenPreviewBinding(
        localDeviceID: screenLocalDeviceID,
        peerDeviceID: screenPeerDeviceID
    ))
    let requestID = try requestID(from: session.start(now: startTime))
    let started = ScreenPreviewMessage.started(requestID: requestID, streamID: fixedScreenStreamID)
        .envelope(sourceDeviceID: screenPeerDeviceID, targetDeviceID: screenLocalDeviceID)
    _ = try session.receive(started, now: startTime)

    for index in 1...3 {
        let now = startTime.advanced(by: .milliseconds(index * 600))
        let idle = ScreenPreviewMessage.idle(
            requestID: requestID,
            streamID: fixedScreenStreamID,
            index: index,
            reason: .frameTooLarge
        ).envelope(sourceDeviceID: screenPeerDeviceID, targetDeviceID: screenLocalDeviceID)
        let update = try session.receive(idle, now: now)
        if index < 3 {
            #expect(!update.ended)
            let pull = session.wake(now: now.advanced(by: .milliseconds(500)))
            try expectPull(pull, requestID: requestID, streamID: fixedScreenStreamID, index: index + 1)
        } else {
            #expect(update.ended)
            #expect(session.phase == .stopped(.captureError))
        }
    }
}

@Test func matchingPeerStopNeverEchoesAtLeaseBoundary() throws {
    let startTime = ContinuousClock.now
    for offset in [Duration.milliseconds(4_999), .seconds(5), .seconds(6)] {
        var session = ScreenPreviewSession(binding: ScreenPreviewBinding(
            localDeviceID: screenLocalDeviceID,
            peerDeviceID: screenPeerDeviceID
        ))
        let requestID = try requestID(from: session.start(now: startTime))
        let stop = ScreenPreviewMessage.stop(requestID: requestID, streamID: nil, reason: .user)
            .envelope(sourceDeviceID: screenPeerDeviceID, targetDeviceID: screenLocalDeviceID)
        let update = try session.receive(stop, now: startTime.advanced(by: offset))
        #expect(update.ended)
        #expect(update.outgoing.isEmpty)
        #expect(session.phase == .stopped(.user))

        let repeated = try session.receive(stop, now: startTime.advanced(by: .seconds(7)))
        #expect(repeated.ignored)
        #expect(repeated.outgoing.isEmpty)
    }

    var streaming = ScreenPreviewSession(binding: ScreenPreviewBinding(
        localDeviceID: screenLocalDeviceID,
        peerDeviceID: screenPeerDeviceID
    ))
    let requestID = try requestID(from: streaming.start(now: startTime))
    let started = ScreenPreviewMessage.started(requestID: requestID, streamID: fixedScreenStreamID)
        .envelope(sourceDeviceID: screenPeerDeviceID, targetDeviceID: screenLocalDeviceID)
    _ = try streaming.receive(started, now: startTime)
    let stop = ScreenPreviewMessage.stop(
        requestID: requestID,
        streamID: fixedScreenStreamID,
        reason: .locked
    ).envelope(sourceDeviceID: screenPeerDeviceID, targetDeviceID: screenLocalDeviceID)
    let update = try streaming.receive(stop, now: startTime.advanced(by: .seconds(5)))
    #expect(update.ended)
    #expect(update.outgoing.isEmpty)
    #expect(streaming.phase == .stopped(.locked))
}

@Test func staleTrafficAndSanitizedRejectionsRespectCurrentSession() throws {
    let startTime = ContinuousClock.now
    var session = ScreenPreviewSession(binding: ScreenPreviewBinding(
        localDeviceID: screenLocalDeviceID,
        peerDeviceID: screenPeerDeviceID
    ))
    let requestID = try requestID(from: session.start(now: startTime))
    let stale = AuthenticatedScreenProtocolRejection(
        peerDeviceID: screenPeerDeviceID,
        requestID: "99999999-9999-4999-8999-999999999999",
        streamID: nil
    )
    #expect(session.receiveAuthenticatedRejection(stale).ignored)
    #expect(session.phase == .requesting)

    let ambiguous = AuthenticatedScreenProtocolRejection(
        peerDeviceID: screenPeerDeviceID,
        requestID: nil,
        streamID: nil
    )
    let ended = session.receiveAuthenticatedRejection(ambiguous)
    #expect(ended.ended)
    #expect(ended.outgoing.count == 1)
    #expect(session.phase == .stopped(.protocolError))

    var other = ScreenPreviewSession(binding: ScreenPreviewBinding(
        localDeviceID: screenLocalDeviceID,
        peerDeviceID: screenPeerDeviceID
    ))
    _ = other.start(now: startTime)
    let ordinary = PlinkEnvelope(
        id: "ordinary",
        type: .deviceStatus,
        sentAt: .now,
        sourceDeviceId: screenPeerDeviceID,
        targetDeviceId: screenLocalDeviceID,
        payload: [:]
    )
    #expect(try other.receive(ordinary, now: startTime).ignored)

    let wrongDirection = ScreenPreviewMessage.started(requestID: requestID, streamID: fixedScreenStreamID)
        .envelope(sourceDeviceID: screenLocalDeviceID, targetDeviceID: screenPeerDeviceID)
    #expect(try other.receive(wrongDirection, now: startTime).ignored)
}

@Test func boundedIngressReleasesFrameAndControlSlots() throws {
    let ingress = ScreenPreviewIngress()
    let generation = UUID()
    let frame = try fixtureFrameEnvelope()
    let firstFrame = try #require(ingress.admit(
        frame,
        expectedSourceDeviceID: screenPeerDeviceID,
        expectedTargetDeviceID: screenLocalDeviceID,
        connectionGeneration: generation
    ))
    #expect(ingress.admit(
        frame,
        expectedSourceDeviceID: screenPeerDeviceID,
        expectedTargetDeviceID: screenLocalDeviceID,
        connectionGeneration: generation
    ) == nil)
    firstFrame.release()
    let secondFrame = try #require(ingress.admit(
        frame,
        expectedSourceDeviceID: screenPeerDeviceID,
        expectedTargetDeviceID: screenLocalDeviceID,
        connectionGeneration: generation
    ))
    secondFrame.release()

    let rejection = AuthenticatedScreenProtocolRejection(
        peerDeviceID: screenPeerDeviceID,
        requestID: nil,
        streamID: nil
    )
    let firstControl = try #require(ingress.admit(
        rejection,
        expectedPeerDeviceID: screenPeerDeviceID,
        connectionGeneration: generation
    ))
    let secondControl = try #require(ingress.admit(
        rejection,
        expectedPeerDeviceID: screenPeerDeviceID,
        connectionGeneration: generation
    ))
    #expect(ingress.admit(
        rejection,
        expectedPeerDeviceID: screenPeerDeviceID,
        connectionGeneration: generation
    ) == nil)
    firstControl.release()
    secondControl.release()
}

private struct SharedScreenFixtures: Decodable {
    let cases: [SharedScreenCase]
    let encryptedVectors: [SharedEncryptedVector]
    let decoderInvalidCases: [SharedDecoderInvalidCase]
}

private struct SharedDecoderInvalidCase: Decodable {
    let name: String
    let width: Int
    let height: Int
    let data: String
}

private struct SharedScreenCase: Decodable {
    let name: String
    let valid: Bool
    let envelope: PlinkEnvelope?
    let rawEnvelope: String?
}

private struct SharedEncryptedVector: Decodable {
    enum CodingKeys: String, CodingKey {
        case name, expectedError, sessionKeyBase64, ivBase64, sequence, nonce, plaintext, frame
        case expectedRequestID = "expectedRequestId"
        case expectedStreamID = "expectedStreamId"
    }
    let name: String
    let expectedError: String?
    let expectedRequestID: String?
    let expectedStreamID: String?
    let sessionKeyBase64: String
    let ivBase64: String
    let sequence: Int64
    let nonce: String
    let plaintext: String
    let frame: EncryptedPlinkFrame
}

private func loadScreenFixtures() throws -> SharedScreenFixtures {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    let url = root.appendingPathComponent("shared/protocol/v1/screen-preview/cases.json")
    return try PlinkJSON.decoder().decode(SharedScreenFixtures.self, from: Data(contentsOf: url))
}

private func fixtureFrameEnvelope() throws -> PlinkEnvelope {
    try #require(loadScreenFixtures().cases.first { $0.name == "baseline jpeg frame" }?.envelope)
}

private func fixtureJPEG() throws -> Data {
    let envelope = try fixtureFrameEnvelope()
    let encoded = try #require(envelope.payload["data"]?.stringValue)
    return try #require(Data(base64Encoded: encoded))
}

private func paddedJSONObject(_ data: Data, byteCount: Int) throws -> Data {
    guard data.count <= byteCount, data.last == UInt8(ascii: "}") else {
        throw PayloadPolicyError.malformedFrame
    }
    var result = data.dropLast()
    result.append(contentsOf: repeatElement(UInt8(ascii: " "), count: byteCount - data.count))
    result.append(UInt8(ascii: "}"))
    return Data(result)
}

private func requestID(from update: ScreenPreviewSessionUpdate) throws -> String {
    let envelope = try #require(update.outgoing.first)
    guard case .request(let requestID) = try ScreenPreviewMessage(envelope: envelope) else {
        throw PayloadPolicyError.malformedFrame
    }
    return requestID
}

private func expectPull(
    _ update: ScreenPreviewSessionUpdate,
    requestID: String,
    streamID: String,
    index: Int
) throws {
    let envelope = try #require(update.outgoing.first)
    guard case .pull(let actualRequestID, let actualStreamID, let actualIndex) =
        try ScreenPreviewMessage(envelope: envelope)
    else {
        throw PayloadPolicyError.malformedFrame
    }
    #expect(actualRequestID == requestID)
    #expect(actualStreamID == streamID)
    #expect(actualIndex == index)
}

private func caughtError<T>(_ body: () throws -> T) -> Error? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

private func caughtError<T>(_ body: () async throws -> T) async -> Error? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

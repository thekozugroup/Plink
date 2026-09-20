import Foundation
import PlinkCore
import Testing

@Test func fileTransferSharedContractVectors() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    let url = root.appendingPathComponent("shared/protocol/v1/file-transfer/cases.json")
    let items = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    for item in items {
        let name = try #require(item["name"] as? String)
        let expected = try #require(item["valid"] as? Bool)
        let raw: Data
        if let original = item["rawEnvelope"] as? String { raw = Data(original.utf8) }
        else { raw = try JSONSerialization.data(withJSONObject: #require(item["envelope"])) }
        let actual: Bool
        do {
            let envelope = try PlinkEnvelope.decode(raw)
            try PayloadPolicy.validate(envelope)
            actual = true
        } catch { actual = false }
        #expect(actual == expected, "\(name)")
    }
}

@Test func maximumFileChunkFitsEncryptedFrame() throws {
    let envelope = PlinkEnvelope(id: "chunk", type: .fileChunk, sentAt: .now,
        sourceDeviceId: "mac", targetDeviceId: "pixel", payload: [
            "transferId": .string("00000000-0000-4000-8000-000000000001"),
            "index": .int(511), "data": .string(Data(repeating: 255, count: 32768).base64EncodedString())
        ])
    let raw = try PlinkJSON.encoder(sortedKeys: true).encode(envelope)
    #expect(raw.count < 65536)
    #expect(!String(decoding: raw, as: UTF8.self).contains("\\/"))
    #expect(try PlinkEnvelope.decode(raw).payload == envelope.payload)
    let codec = EncryptedFrameCodec(sessionKey: Data(repeating: 7, count: 32))
    let frame = try codec.seal(envelope, sequence: 1)
    #expect(try PlinkJSON.encoder(sortedKeys: true).encode(frame).count < 131072)
    #expect(try codec.open(frame).payload == envelope.payload)
}

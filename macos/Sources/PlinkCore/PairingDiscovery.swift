import Foundation

public enum PairingDiscoveryError: Error, Equatable {
    case missingField(String)
    case unsupportedProtocol
}

public enum PairingBonjour {
    public static let serviceType = "_plink._tcp."
    public static let domain = "local."

    public static func txtRecord(for offer: PairingOffer) -> [String: Data] {
        [
            "plink": Data("1".utf8),
            "deviceId": Data(offer.deviceId.utf8),
            "deviceName": Data(offer.deviceName.utf8),
            "platform": Data(offer.platform.utf8),
            "endpoint": Data(offer.endpoint.utf8),
            "nonce": Data(offer.nonce.utf8),
            "publicKey": Data(offer.publicKey.utf8),
            "targetDeviceId": Data(offer.targetDeviceId.utf8),
            "protocolVersion": Data(String(offer.protocolVersion).utf8)
        ]
    }

    public static func offer(
        from txtRecord: [String: Data],
        endpointHost: String? = nil,
        port: Int? = nil
    ) throws -> PairingOffer {
        guard optionalString("plink", in: txtRecord) == "1" else {
            throw PairingDiscoveryError.unsupportedProtocol
        }
        let protocolVersion = Int(try string("protocolVersion", in: txtRecord)) ?? 0
        guard protocolVersion == 1 else {
            throw PairingDiscoveryError.unsupportedProtocol
        }
        let endpoint = optionalString("endpoint", in: txtRecord)
            ?? endpointHost.flatMap { host in port.map { "\(host):\($0)" } }
        guard let endpoint, endpoint.isEmpty == false else {
            throw PairingDiscoveryError.missingField("endpoint")
        }
        return PairingOffer(
            deviceId: try string("deviceId", in: txtRecord),
            deviceName: try string("deviceName", in: txtRecord),
            platform: try string("platform", in: txtRecord),
            endpoint: endpoint,
            nonce: try string("nonce", in: txtRecord),
            publicKey: try string("publicKey", in: txtRecord),
            targetDeviceId: try string("targetDeviceId", in: txtRecord),
            protocolVersion: protocolVersion
        )
    }

    private static func string(_ key: String, in txtRecord: [String: Data]) throws -> String {
        guard let value = optionalString(key, in: txtRecord), value.isEmpty == false else {
            throw PairingDiscoveryError.missingField(key)
        }
        return value
    }

    private static func optionalString(_ key: String, in txtRecord: [String: Data]) -> String? {
        txtRecord[key].flatMap { String(data: $0, encoding: .utf8) }
    }
}

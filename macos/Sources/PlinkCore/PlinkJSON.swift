import Foundation

public enum PlinkJSON {
    public static func encoder(sortedKeys: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Formatter(includeFractionalSeconds: false).string(from: date))
        }
        if sortedKeys {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = iso8601Formatter(includeFractionalSeconds: true).date(from: value)
                ?? iso8601Formatter(includeFractionalSeconds: false).date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Date is not valid ISO 8601."
            )
        }
        return decoder
    }

    private static func iso8601Formatter(includeFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = includeFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

import Foundation

/// Display labels only; never supplies notification or action identity.
@MainActor
enum NotificationArtwork {
    static func label(_ value: String?) -> String {
        let scalars = (value ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) &&
                $0.properties.generalCategory != .format
        }.prefix(80)
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func subtitle(appName: String?, phoneName: String?) -> String {
        let app = label(appName)
        let phone = label(phoneName)
        let origin = phone.isEmpty ? "Phone" : phone
        return app.isEmpty ? origin : "\(app) · \(origin)"
    }

}

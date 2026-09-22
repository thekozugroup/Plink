import AppKit
import ImageIO
import UniformTypeIdentifiers
import UserNotifications

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

    /// Decode only the bounded single-image wire format, then compose locally.
    static func renderedPNG(_ base64: String?) -> Data? {
        guard let base64, base64.utf8.count <= 21_848,
              let data = Data(base64Encoded: base64), data.count <= 16_384,
              isStaticPNG(data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...96).contains(width), (1...96).contains(height),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8,
                  bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(96 / CGFloat(width), 96 / CGFloat(height))
        let size = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        context.draw(image, in: CGRect(x: (96 - size.width) / 2, y: (96 - size.height) / 2,
                                      width: size.width, height: size.height))
        if let phone = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 69, y: 1, width: 26, height: 26))
            context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
            context.setLineWidth(1)
            context.strokeEllipse(in: CGRect(x: 69.5, y: 1.5, width: 25, height: 25))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            phone.draw(in: CGRect(x: 77, y: 5, width: 10, height: 18))
            NSGraphicsContext.restoreGraphicsState()
        } // A missing system symbol leaves the original artwork and phone subtitle.
        guard let composed = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, composed, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 16_384 else { return nil }
        return output as Data
    }

    private static func isStaticPNG(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= bytes.count - offset - 12 else { return false }
            let type = Array(bytes[offset + 4..<offset + 8])
            if type == [97, 99, 84, 76] { return false } // acTL: reject APNG before pixel decode.
            offset += length + 12
            if type == [73, 69, 78, 68] { return length == 0 && offset == bytes.count }
        }
        return false
    }

    struct Stage {
        let id: UUID
        let attachment: UNNotificationAttachment
    }

    /// Counts all unfinished decorated submissions, including superseded owners.
    @MainActor final class Staging {
        private let directory: URL
        private var pending: [UUID: URL] = [:]
        var pendingCount: Int { pending.count }

        init(directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plink-notification-artwork", isDirectory: true)) {
            self.directory = directory
            // A new bridge is created at startup. Only our UUID-named staging directories
            // are orphan candidates; never touch the notification daemon's moved files.
            for url in (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil)) ?? [] {
                let name = url.lastPathComponent
                if name.hasPrefix("submission-"), UUID(uuidString: String(name.dropFirst(11))) != nil {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        func stage(_ base64: String?) -> Stage? {
            guard pending.count < 128, let png = NotificationArtwork.renderedPNG(base64) else { return nil }
            let id = UUID()
            let owned = directory.appendingPathComponent("submission-\(id.uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
                let file = owned.appendingPathComponent("source.png")
                try png.write(to: file, options: .atomic)
                let attachment = try UNNotificationAttachment(identifier: "source-app", url: file, options: nil)
                pending[id] = owned
                return Stage(id: id, attachment: attachment)
            } catch {
                try? FileManager.default.removeItem(at: owned)
                return nil
            }
        }

        func finish(_ stage: Stage) {
            guard let owned = pending.removeValue(forKey: stage.id) else { return }
            try? FileManager.default.removeItem(at: owned)
        }
    }
}

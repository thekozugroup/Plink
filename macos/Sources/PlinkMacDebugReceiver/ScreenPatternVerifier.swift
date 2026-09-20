import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Checks decoded pixels from the debug-only Android activity, never JPEG metadata.
enum ScreenPatternVerifier {
    struct Observation {
        let pixelSHA256: String
        let markerColumn: Int
        let markerIsMagenta: Bool
    }

    static func inspect(_ image: CGImage) throws -> Observation? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 1280, height <= 1280,
              width * height <= 921_600 else { throw failure("Invalid decoded dimensions") }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw failure("Cannot allocate synthetic pixel check") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = (y * width + x) * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }
        // Search the stripe row rather than assuming status-bar, navigation-bar or
        // app-only capture insets. Require all four colors in their spatial order.
        let columns = [1, 3, 5, 7].map { width * $0 / 8 }
        var stripeRows = 0
        for y in stride(from: 0, to: height, by: 3) {
            let a = color(columns[0], y), b = color(columns[1], y)
            let c = color(columns[2], y), d = color(columns[3], y)
            if a.0 > 180 && a.1 < 80 && a.2 < 80 &&
                b.0 < 80 && b.1 > 180 && b.2 < 80 &&
                c.0 < 80 && c.1 < 80 && c.2 > 180 &&
                d.0 > 180 && d.1 > 180 && d.2 < 80 { stripeRows += 1 }
        }
        guard stripeRows >= max(3, height / 60) else { return nil }
        var magenta = (count: 0, sumX: 0), cyan = (count: 0, sumX: 0)
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                let p = color(x, y)
                if p.0 > 180 && p.1 < 80 && p.2 > 180 { magenta.count += 1; magenta.sumX += x }
                if p.0 < 80 && p.1 > 180 && p.2 > 180 { cyan.count += 1; cyan.sumX += x }
            }
        }
        let isMagenta = magenta.count > cyan.count
        let marker = isMagenta ? magenta : cyan
        guard marker.count >= max(8, width * height / 9000) else { return nil }
        return Observation(pixelSHA256: SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined(),
            markerColumn: marker.sumX / marker.count, markerIsMagenta: isMagenta)
    }

    /// Test evidence only. The production screen preview never records frames.
    static func saveEvidence(_ image: CGImage, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw failure("Refusing to replace screen evidence") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure("Cannot write screen evidence") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PlinkScreenPattern", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

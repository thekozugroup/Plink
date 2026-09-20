#!/usr/bin/env swift
import AppKit
import Foundation

// Static asset source: Lucide link.svg at 951813ce76a859d4d8b145366972cbb237147a4e (ISC).
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appending(path: "macos/Resources/Plink.icns")
let work = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "plink-icon-\(UUID().uuidString)")
let iconset = work.appending(path: "Plink.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func linkPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 10, y: 13))
    path.addCurve(to: CGPoint(x: 13.6466, y: 14.9923), control1: CGPoint(x: 10.869, y: 14.1617), control2: CGPoint(x: 12.1996, y: 14.8887))
    path.addCurve(to: CGPoint(x: 17.54, y: 13.54), control1: CGPoint(x: 15.0937, y: 15.096), control2: CGPoint(x: 16.5144, y: 14.566))
    path.addLine(to: CGPoint(x: 20.54, y: 10.54))
    path.addCurve(to: CGPoint(x: 20.4791, y: 3.53091), control1: CGPoint(x: 22.4349, y: 8.57811), control2: CGPoint(x: 22.4078, y: 5.45958))
    path.addCurve(to: CGPoint(x: 13.47, y: 3.47), control1: CGPoint(x: 18.5504, y: 1.60224), control2: CGPoint(x: 15.4319, y: 1.57514))
    path.addLine(to: CGPoint(x: 11.75, y: 5.18))
    path.move(to: CGPoint(x: 14, y: 11))
    path.addCurve(to: CGPoint(x: 10.3534, y: 9.00767), control1: CGPoint(x: 13.131, y: 9.83831), control2: CGPoint(x: 11.8004, y: 9.1113))
    path.addCurve(to: CGPoint(x: 6.46, y: 10.46), control1: CGPoint(x: 8.90633, y: 8.90403), control2: CGPoint(x: 7.48563, y: 9.43399))
    path.addLine(to: CGPoint(x: 3.46, y: 13.46))
    path.addCurve(to: CGPoint(x: 3.52091, y: 20.4691), control1: CGPoint(x: 1.56514, y: 15.4219), control2: CGPoint(x: 1.59224, y: 18.5404))
    path.addCurve(to: CGPoint(x: 10.53, y: 20.53), control1: CGPoint(x: 5.44958, y: 22.3978), control2: CGPoint(x: 8.56811, y: 22.4249))
    path.addLine(to: CGPoint(x: 12.24, y: 18.82))
    return path
}

func png(size: Int, name: String) throws {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let context = NSGraphicsContext.current!.cgContext
        let inset = rect.width * 0.0625
        let background = CGRect(x: inset, y: inset, width: rect.width - inset * 2, height: rect.height - inset * 2)
        context.setFillColor(NSColor(red: 0.949, green: 0.957, blue: 0.969, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: background, cornerWidth: rect.width * 0.203, cornerHeight: rect.width * 0.203, transform: nil))
        context.fillPath()
        context.saveGState()
        let scale = rect.width / 24 * 0.72
        context.translateBy(x: rect.midX - 12 * scale, y: rect.midY + 12 * scale)
        context.scaleBy(x: scale, y: -scale)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(linkPath())
        context.strokePath()
        context.restoreGState()
        return true
    }
    guard let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!), let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: iconset.appending(path: name))
}

for (size, name) in [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")] {
    try png(size: size, name: name)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }

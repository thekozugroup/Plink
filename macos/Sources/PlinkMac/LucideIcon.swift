import AppKit
import SwiftUI

// Paths copied from Lucide commit 951813ce76a859d4d8b145366972cbb237147a4e (ISC).
struct LucideIcon: View {
    enum Name: Sendable {
        case battery, batteryCharging, bell, bellOff, bluetooth, circleCheck, laptop, link
        case monitorOff, monitorSmartphone, phone, shieldCheck, smartphone, video, wifi, wifiOff
    }

    let name: Name
    let size: CGFloat

    init(name: Name, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        LucideShape(name: name)
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static var menuBarLink: Image {
        Image(nsImage: menuBarLinkImage)
    }

    private static let menuBarLinkImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let context = NSGraphicsContext.current!.cgContext
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: 1, y: -1)
            context.addPath(LucideShape(name: .link).path(in: rect).cgPath)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private struct LucideShape: Shape {
    let name: LucideIcon.Name

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let offset = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        var path = Path()
        switch name {
        case .bluetooth:
            path.move(to: point(7, 7)); path.addLine(to: point(17, 17)); path.addLine(to: point(12, 22)); path.addLine(to: point(12, 2)); path.addLine(to: point(17, 7)); path.addLine(to: point(7, 17))
        case .link:
            path.move(to: point(10, 13)); path.addCurve(to: point(13.6466, 14.9923), control1: point(10.869, 14.1617), control2: point(12.1996, 14.8887))
            path.addCurve(to: point(17.54, 13.54), control1: point(15.0937, 15.096), control2: point(16.5144, 14.566))
            path.addLine(to: point(20.54, 10.54)); path.addCurve(to: point(20.4791, 3.53091), control1: point(22.4349, 8.57811), control2: point(22.4078, 5.45958))
            path.addCurve(to: point(13.47, 3.47), control1: point(18.5504, 1.60224), control2: point(15.4319, 1.57514))
            path.addLine(to: point(11.75, 5.18))
            path.move(to: point(14, 11)); path.addCurve(to: point(10.3534, 9.00767), control1: point(13.131, 9.83831), control2: point(11.8004, 9.1113))
            path.addCurve(to: point(6.46, 10.46), control1: point(8.90633, 8.90403), control2: point(7.48563, 9.43399))
            path.addLine(to: point(3.46, 13.46)); path.addCurve(to: point(3.52091, 20.4691), control1: point(1.56514, 15.4219), control2: point(1.59224, 18.5404))
            path.addCurve(to: point(10.53, 20.53), control1: point(5.44958, 22.3978), control2: point(8.56811, 22.4249))
            path.addLine(to: point(12.24, 18.82))
        case .phone:
            path.move(to: point(13.832, 16.568)); path.addCurve(to: point(15.045, 16.265), control1: point(14.254, 16.99), control2: point(14.816, 16.85))
            path.addLine(to: point(15.4, 15.8)); path.addCurve(to: point(17, 15), control1: point(15.78, 15.3), control2: point(16.35, 15))
            path.addLine(to: point(20, 15)); path.addCurve(to: point(22, 17), control1: point(21.1, 15), control2: point(22, 15.9))
            path.addLine(to: point(22, 20)); path.addCurve(to: point(20, 22), control1: point(22, 21.1), control2: point(21.1, 22))
            path.addCurve(to: point(2, 4), control1: point(10.06, 22), control2: point(2, 13.94))
            path.addCurve(to: point(4, 2), control1: point(2, 2.9), control2: point(2.9, 2))
            path.addLine(to: point(7, 2)); path.addCurve(to: point(9, 4), control1: point(8.1, 2), control2: point(9, 2.9))
            path.addLine(to: point(9, 7)); path.addCurve(to: point(8.2, 8.6), control1: point(9, 7.7), control2: point(8.7, 8.3))
            path.addLine(to: point(7.732, 8.951)); path.addCurve(to: point(7.44, 10.184), control1: point(7.45, 9.16), control2: point(7.33, 9.72))
            path.addCurve(to: point(13.832, 16.568), control1: point(8.88, 12.91), control2: point(11.09, 15.12))
        case .smartphone:
            path.addRoundedRect(in: CGRect(x: 5, y: 2, width: 14, height: 20), cornerSize: CGSize(width: 2, height: 2))
            path.move(to: point(12, 18)); path.addLine(to: point(12.01, 18))
        case .laptop:
            path.move(to: point(18, 5)); path.addCurve(to: point(20, 7), control1: point(19.1, 5), control2: point(20, 5.9))
            path.addLine(to: point(20, 15.526)); path.addCurve(to: point(20.212, 16.423), control1: point(20, 15.85), control2: point(20.07, 16.16))
            path.addLine(to: point(21.28, 18.55)); path.addCurve(to: point(20.38, 20), control1: point(21.58, 19.14), control2: point(21.15, 20))
            path.addLine(to: point(3.62, 20)); path.addCurve(to: point(2.72, 18.55), control1: point(2.85, 20), control2: point(2.42, 19.14))
            path.addLine(to: point(3.788, 16.423)); path.addCurve(to: point(4, 15.526), control1: point(3.93, 16.16), control2: point(4, 15.85))
            path.addLine(to: point(4, 7)); path.addCurve(to: point(6, 5), control1: point(4, 5.9), control2: point(4.9, 5)); path.closeSubpath()
            path.move(to: point(20.054, 15.987)); path.addLine(to: point(3.946, 15.987))
        case .shieldCheck:
            path.move(to: point(20, 13)); path.addCurve(to: point(12.34, 21.95), control1: point(20, 18), control2: point(16.5, 20.5))
            path.addCurve(to: point(11.67, 21.94), control1: point(12.12, 22.03), control2: point(11.9, 22.03))
            path.addCurve(to: point(4, 13), control1: point(7.5, 20.5), control2: point(4, 18)); path.addLine(to: point(4, 6))
            path.addCurve(to: point(5, 5), control1: point(4, 5.45), control2: point(4.45, 5)); path.addCurve(to: point(11.24, 2.28), control1: point(7, 5), control2: point(9.5, 3.8))
            path.addCurve(to: point(12.76, 2.28), control1: point(11.68, 1.9), control2: point(12.32, 1.9))
            path.addCurve(to: point(19, 5), control1: point(14.51, 3.81), control2: point(17, 5)); path.addCurve(to: point(20, 6), control1: point(19.55, 5), control2: point(20, 5.45)); path.closeSubpath()
            path.move(to: point(9, 12)); path.addLine(to: point(11, 14)); path.addLine(to: point(15, 10))
        case .circleCheck:
            path.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20)); path.move(to: point(16, 9)); path.addLine(to: point(10.5, 14.5)); path.addLine(to: point(8, 12))
        case .video:
            path.move(to: point(16, 13)); path.addLine(to: point(21.223, 16.482)); path.addCurve(to: point(22, 16.066), control1: point(21.63, 16.75), control2: point(22, 16.46))
            path.addLine(to: point(22, 7.87)); path.addCurve(to: point(21.248, 7.438), control1: point(22, 7.49), control2: point(21.59, 7.24)); path.addLine(to: point(16, 10.5))
            path.move(to: point(4, 6)); path.addLine(to: point(14, 6)); path.addQuadCurve(to: point(16, 8), control: point(16, 6)); path.addLine(to: point(16, 16)); path.addQuadCurve(to: point(14, 18), control: point(16, 18)); path.addLine(to: point(4, 18)); path.addQuadCurve(to: point(2, 16), control: point(2, 18)); path.addLine(to: point(2, 8)); path.addQuadCurve(to: point(4, 6), control: point(2, 6))
        case .bell:
            path.move(to: point(10.268, 21)); path.addCurve(to: point(13.732, 21), control1: point(11.11, 22.33), control2: point(12.89, 22.33))
            path.move(to: point(3.262, 15.326)); path.addCurve(to: point(4, 17), control1: point(2.8, 15.84), control2: point(3.24, 17)); path.addLine(to: point(20, 17)); path.addCurve(to: point(20.738, 15.326), control1: point(20.76, 17), control2: point(21.2, 15.84)); path.addCurve(to: point(18, 8), control1: point(19.41, 13.956), control2: point(18, 12.499)); path.addCurve(to: point(6, 8), control1: point(18, 4.686), control2: point(6, 4.686)); path.addCurve(to: point(3.262, 15.326), control1: point(6, 12.499), control2: point(4.59, 13.956))
        case .bellOff:
            path.move(to: point(10.268, 21)); path.addCurve(to: point(13.732, 21), control1: point(11.11, 22.33), control2: point(12.89, 22.33))
            path.move(to: point(17, 17)); path.addLine(to: point(4, 17)); path.addCurve(to: point(3.26, 15.327), control1: point(3.24, 17), control2: point(2.8, 15.84)); path.addCurve(to: point(6, 8), control1: point(4.59, 13.956), control2: point(6, 12.499)); path.addCurve(to: point(6.258, 6.258), control1: point(6, 7.4), control2: point(6.09, 6.82))
            path.move(to: point(2, 2)); path.addLine(to: point(22, 22)); path.move(to: point(8.668, 3.01)); path.addCurve(to: point(18, 8), control1: point(12.3, 1.8), control2: point(18, 4.56)); path.addCurve(to: point(19.707, 14.05), control1: point(18, 10.687), control2: point(18.77, 12.653))
        case .wifi:
            path.move(to: point(12, 20)); path.addLine(to: point(12.01, 20)); path.move(to: point(2, 8.82)); path.addCurve(to: point(22, 8.82), control1: point(7.5, 3.34), control2: point(16.5, 3.34)); path.move(to: point(5, 12.859)); path.addCurve(to: point(19, 12.859), control1: point(8.85, 9.01), control2: point(15.15, 9.01)); path.move(to: point(8.5, 16.429)); path.addCurve(to: point(15.5, 16.429), control1: point(10.43, 14.5), control2: point(13.57, 14.5))
        case .wifiOff:
            path.move(to: point(12, 20)); path.addLine(to: point(12.01, 20)); path.move(to: point(8.5, 16.429)); path.addCurve(to: point(15.5, 16.429), control1: point(10.43, 14.5), control2: point(13.57, 14.5)); path.move(to: point(5, 12.859)); path.addCurve(to: point(10.17, 10.169), control1: point(6.57, 11.29), control2: point(8.3, 10.39)); path.move(to: point(19, 12.859)); path.addCurve(to: point(16.993, 11.336), control1: point(18.43, 12.29), control2: point(17.76, 11.78)); path.move(to: point(2, 8.82)); path.addCurve(to: point(6.177, 6.177), control1: point(3.21, 7.61), control2: point(4.61, 6.73)); path.move(to: point(22, 8.82)); path.addCurve(to: point(10.712, 5.056), control1: point(18.89, 5.71), control2: point(15.1, 4.45)); path.move(to: point(2, 2)); path.addLine(to: point(22, 22))
        case .battery:
            path.move(to: point(22, 14)); path.addLine(to: point(22, 10)); path.addRoundedRect(in: CGRect(x: 2, y: 6, width: 16, height: 12), cornerSize: CGSize(width: 2, height: 2))
        case .batteryCharging:
            path.move(to: point(11, 7)); path.addLine(to: point(8, 12)); path.addLine(to: point(12, 12)); path.addLine(to: point(9, 17)); path.move(to: point(14.856, 6)); path.addLine(to: point(16, 6)); path.addCurve(to: point(18, 8), control1: point(17.1, 6), control2: point(18, 6.9)); path.addLine(to: point(18, 16)); path.addCurve(to: point(16, 18), control1: point(18, 17.1), control2: point(17.1, 18)); path.addLine(to: point(13.065, 18)); path.move(to: point(22, 14)); path.addLine(to: point(22, 10)); path.move(to: point(5.14, 18)); path.addLine(to: point(4, 18)); path.addCurve(to: point(2, 16), control1: point(2.9, 18), control2: point(2, 17.1)); path.addLine(to: point(2, 8)); path.addCurve(to: point(4, 6), control1: point(2, 6.9), control2: point(2.9, 6)); path.addLine(to: point(6.936, 6))
        case .monitorSmartphone:
            path.move(to: point(18, 8)); path.addLine(to: point(18, 6)); path.addCurve(to: point(16, 4), control1: point(18, 4.9), control2: point(17.1, 4)); path.addLine(to: point(4, 4)); path.addCurve(to: point(2, 6), control1: point(2.9, 4), control2: point(2, 4.9)); path.addLine(to: point(2, 13)); path.addCurve(to: point(4, 15), control1: point(2, 14.1), control2: point(2.9, 15)); path.addLine(to: point(12, 15)); path.move(to: point(10, 19)); path.addLine(to: point(10, 15.04)); path.move(to: point(7, 19)); path.addLine(to: point(12, 19)); path.addRoundedRect(in: CGRect(x: 16, y: 12, width: 6, height: 10), cornerSize: CGSize(width: 2, height: 2))
        case .monitorOff:
            path.move(to: point(12, 17)); path.addLine(to: point(12, 21)); path.move(to: point(17, 17)); path.addLine(to: point(4, 17)); path.addCurve(to: point(2, 15), control1: point(2.9, 17), control2: point(2, 16.1)); path.addLine(to: point(2, 5)); path.addCurve(to: point(3.184, 3.174), control1: point(2, 4.2), control2: point(2.45, 3.48)); path.move(to: point(2, 2)); path.addLine(to: point(22, 22)); path.move(to: point(8, 21)); path.addLine(to: point(16, 21)); path.move(to: point(8.656, 3)); path.addLine(to: point(20, 3)); path.addCurve(to: point(22, 5), control1: point(21.1, 3), control2: point(22, 3.9)); path.addLine(to: point(22, 15)); path.addCurve(to: point(21.707, 16.042), control1: point(22, 15.36), control2: point(21.9, 15.71))
        }
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: offset.x / scale, y: offset.y / scale))
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
}

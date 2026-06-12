import AppKit
import Foundation

enum TaskStatusStripIcon {
    static func make(snapshot: TaskStatusSnapshot, frame: Int) -> NSImage {
        let segments = snapshot.menuSegments
        if segments.isEmpty {
            return standingIcon()
        }

        let measurements = segments.map { segment in
            let label = countText(segment.count)
            return SegmentMeasurement(
                kind: segment.kind,
                count: segment.count,
                label: label,
                width: 18 + countWidth(label) + 5
            )
        }
        let width = max(18, measurements.reduce(CGFloat(0)) { $0 + $1.width + 3 } - 3)
        let size = NSSize(width: width, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        var x: CGFloat = 0
        for measurement in measurements {
            drawGlyph(kind: measurement.kind, in: NSRect(x: x, y: 1, width: 17, height: 16), frame: frame)
            drawCount(measurement.label, kind: measurement.kind, x: x + 17, y: 4)
            x += measurement.width + 3
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private struct SegmentMeasurement {
        let kind: TaskStatusKind
        let count: Int
        let label: String
        let width: CGFloat
    }

    private static func standingIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        drawStatusSymbol("figure.stand", in: NSRect(x: 1, y: 1, width: 16, height: 16), color: color(for: .idle), pointSize: 14.5)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func countText(_ value: Int) -> String {
        value > 99 ? "99+" : "\(max(value, 0))"
    }

    private static func countWidth(_ text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        return max(13, ceil(size.width) + 7)
    }

    private static func drawCount(_ text: String, kind: TaskStatusKind, x: CGFloat, y: CGFloat) {
        let width = countWidth(text)
        let rect = NSRect(x: x, y: y, width: width, height: 10)
        color(for: kind).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2 + 0.2),
            withAttributes: attributes
        )
    }

    private static func drawGlyph(kind: TaskStatusKind, in rect: NSRect, frame: Int) {
        switch kind {
        case .error:
            drawErrorSymbol(in: rect, color: color(for: kind))
        case .needsConfirmation:
            drawConfirmationSymbol(in: rect, color: color(for: kind), frame: frame)
        case .needsReply:
            drawReplySymbol(in: rect, color: color(for: kind), frame: frame)
        case .running:
            drawRunningSymbol(in: rect, color: color(for: kind), frame: frame)
        case .completedUnread:
            drawCompletedSymbol(in: rect, color: color(for: kind), frame: frame)
        case .idle, .unknown:
            drawStatusSymbol("figure.stand", in: rect.insetBy(dx: 0.5, dy: 0), color: color(for: kind), pointSize: 14.5)
        }
    }

    private static func color(for kind: TaskStatusKind) -> NSColor {
        switch kind {
        case .error:
            return NSColor(calibratedRed: 0.94, green: 0.25, blue: 0.22, alpha: 1)
        case .needsConfirmation:
            return NSColor(calibratedRed: 0.92, green: 0.62, blue: 0.18, alpha: 1)
        case .needsReply:
            return NSColor(calibratedRed: 0.46, green: 0.52, blue: 0.95, alpha: 1)
        case .running:
            return NSColor(calibratedRed: 0.16, green: 0.58, blue: 0.88, alpha: 1)
        case .completedUnread:
            return NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.42, alpha: 1)
        case .idle, .unknown:
            return NSColor(calibratedWhite: 0.56, alpha: 1)
        }
    }

    private static func drawRunningSymbol(in rect: NSRect, color: NSColor, frame: Int) {
        let phase = frame % 3
        let dx = phase == 1 ? CGFloat(0.4) : CGFloat(0)
        let dy = phase == 1 ? CGFloat(0.35) : CGFloat(0)

        drawMotionDash(in: rect, y: rect.minY + 4.6, length: phase == 1 ? 4.5 : 3.3, color: color)
        drawMotionDash(in: rect, y: rect.minY + 7.9, length: phase == 2 ? 4.2 : 3.0, color: color.withAlphaComponent(0.32))
        drawStatusSymbol(
            "figure.run",
            in: rect.offsetBy(dx: dx, dy: dy).insetBy(dx: -0.3, dy: -0.2),
            color: color,
            pointSize: 15.2,
            weight: .semibold
        )
    }

    private static func drawCompletedSymbol(in rect: NSRect, color: NSColor, frame: Int) {
        let bounce = frame % 2 == 0 ? CGFloat(0) : CGFloat(0.65)
        drawStatusSymbol(
            "figure.arms.open",
            in: rect.offsetBy(dx: 0, dy: bounce).insetBy(dx: -0.3, dy: -0.2),
            color: color,
            pointSize: 15.0,
            weight: .semibold
        )
        drawDot(center: NSPoint(x: rect.minX + 3.2, y: rect.maxY - 3.6 + bounce), radius: 0.8, color: color.withAlphaComponent(0.68))
        drawDot(center: NSPoint(x: rect.maxX - 3.2, y: rect.maxY - 3.6 + bounce), radius: 0.8, color: color.withAlphaComponent(0.68))
    }

    private static func drawConfirmationSymbol(in rect: NSRect, color: NSColor, frame: Int) {
        let press = frame % 2 == 0 ? CGFloat(0) : CGFloat(-0.45)
        drawDot(center: NSPoint(x: rect.midX, y: rect.minY + 3.0), radius: 4.6, color: color.withAlphaComponent(0.13))
        drawStatusSymbol(
            "hand.tap.fill",
            in: rect.offsetBy(dx: 0.1, dy: press).insetBy(dx: 0.2, dy: -0.1),
            color: color,
            pointSize: 14.6,
            weight: .semibold
        )
    }

    private static func drawReplySymbol(in rect: NSRect, color: NSColor, frame: Int) {
        drawStatusSymbol(
            "ellipsis.bubble.fill",
            in: rect.insetBy(dx: 0.2, dy: 0.0),
            color: color,
            pointSize: 14.5,
            weight: .semibold
        )

        let activeDot = frame % 3
        for index in 0..<3 {
            let alpha = index == activeDot ? CGFloat(0.95) : CGFloat(0.35)
            drawDot(
                center: NSPoint(x: rect.minX + 5.5 + CGFloat(index) * 2.5, y: rect.minY + 8.7),
                radius: index == activeDot ? 0.85 : 0.65,
                color: NSColor.white.withAlphaComponent(alpha)
            )
        }
    }

    private static func drawErrorSymbol(in rect: NSRect, color: NSColor) {
        drawStatusSymbol(
            "figure.stand",
            in: NSRect(x: rect.minX + 0.1, y: rect.minY, width: 12.6, height: rect.height),
            color: color,
            pointSize: 14.1,
            weight: .semibold
        )
        drawDot(center: NSPoint(x: rect.maxX - 3.6, y: rect.maxY - 4.0), radius: 3.25, color: color)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .black),
            .foregroundColor: NSColor.white
        ]
        ("!" as NSString).draw(at: NSPoint(x: rect.maxX - 4.8, y: rect.maxY - 8.15), withAttributes: attributes)
    }

    private static func drawStatusSymbol(
        _ name: String,
        in rect: NSRect,
        color: NSColor,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular
    ) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else {
            return
        }

        symbol.draw(in: aspectFit(symbol.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func aspectFit(_ imageSize: NSSize, in rect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return rect
        }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func drawMotionDash(in rect: NSRect, y: CGFloat, length: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 1.35
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: rect.minX + 1.4, y: y))
        path.line(to: NSPoint(x: rect.minX + 1.4 + length, y: y))
        color.withAlphaComponent(0.26).setStroke()
        path.stroke()
    }

    private static func drawDot(center: NSPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
}

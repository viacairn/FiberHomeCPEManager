import AppKit
import SwiftUI
import FHCPECore

/// The entire menu-bar segment is drawn into one fixed-size template image.
///
/// Why not compose `HStack { Image; Text }`: a `MenuBarExtra` label is laid out at its
/// intrinsic content size, and `.frame(width:)` inside the label is ignored by the system
/// item. Measured widths for a text-based label drifted 87–108 pt whenever the rate text
/// changed. Drawing one template bitmap fixes the segment at an exact size.
///
/// All geometry comes from `MenuBarGeometry` so that this renderer and the tests can never
/// disagree about bar sizes or the segment width.
public enum MenuBarGlyph {
    public static let height = MenuBarGeometry.height

    public static var payloadWidth: CGFloat { MenuBarGeometry.payloadWidth }

    public static func width(for style: MenuBarStyle) -> CGFloat {
        MenuBarGeometry.width(for: style)
    }

    /// The five signal states the glyph must distinguish (mapping tested in the core suite).
    public typealias Level = MenuBarGeometry.SignalState

    /// Renders the segment from a raw bar count (nil = unknown).
    public static func image(style: MenuBarStyle, level: Int?, text: String,
                             connected: Bool = true) -> NSImage {
        image(style: style, level: Level(level), text: text, connected: connected)
    }

    public static func image(style: MenuBarStyle, level: Level, text: String,
                             connected: Bool = true) -> NSImage {
        let width = width(for: style)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            drawBars(level, connected: connected)
            drawText(text, width: width, connected: connected)
            if !connected { drawDisconnectedBadge() }
            return true
        }
        // A template image is tinted by the menu bar, which would also tint the red badge.
        // Disconnected keeps real colours and resolves its grey through the system palette.
        image.isTemplate = connected
        return image
    }

    /// Red "not connected" mark at the bottom-right of the glyph.
    private static func drawDisconnectedBadge() {
        let diameter: CGFloat = 7
        let marker = NSRect(x: MenuBarGeometry.barsWidth - diameter + 1,
                            y: 0.5,
                            width: diameter,
                            height: diameter)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: marker).fill()
        let cross = NSBezierPath()
        let inset: CGFloat = 2.1
        cross.lineWidth = 1.2
        cross.lineCapStyle = .round
        cross.move(to: NSPoint(x: marker.minX + inset, y: marker.minY + inset))
        cross.line(to: NSPoint(x: marker.maxX - inset, y: marker.maxY - inset))
        cross.move(to: NSPoint(x: marker.minX + inset, y: marker.maxY - inset))
        cross.line(to: NSPoint(x: marker.maxX - inset, y: marker.minY + inset))
        NSColor.white.setStroke()
        cross.stroke()
    }

    /// Template images are tinted by the system; real-colour images must resolve their ink
    /// through the palette so they stay legible in dark mode.
    private static func ink(_ alpha: CGFloat, connected: Bool) -> NSColor {
        connected ? NSColor.black.withAlphaComponent(alpha)
                  : NSColor.labelColor.withAlphaComponent(alpha)
    }

    // MARK: - Bars

    private static func drawBars(_ level: Level, connected: Bool = true) {
        for index in 0..<MenuBarGeometry.barCount {
            let rect = NSRect(x: MenuBarGeometry.barOrigin(index),
                              y: MenuBarGeometry.barTop,
                              width: MenuBarGeometry.barWidth,
                              height: MenuBarGeometry.barHeight(index))
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: MenuBarGeometry.barWidth / 2,
                                    yRadius: MenuBarGeometry.barWidth / 2)
            switch level {
            case .unknown:
                // Hollow: clearly "no information", not "weak signal".
                ink(0.55, connected: connected).setStroke()
                path.lineWidth = 1
                path.stroke()
            case .none:
                ink(0.26, connected: connected).setFill()
                path.fill()
            case .bars(let filled):
                // A template image only carries alpha, so filled vs empty is expressed by
                // alpha, which the system then inverts for light/dark menu bars.
                (index < filled ? ink(1, connected: connected) : ink(0.26, connected: connected)).setFill()
                path.fill()
            }
        }
    }

    // MARK: - Text

    private static func drawText(_ text: String, width: CGFloat, connected: Bool = true) {
        let cellX = MenuBarGeometry.barsWidth + MenuBarGeometry.gap
        let cellWidth = width - cellX
        let base = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        var value = NSAttributedString(string: text, attributes: [
            .font: base, .foregroundColor: ink(1, connected: connected)
        ])
        var measured = value.size()
        // Never let the text exceed its cell: shrink proportionally instead of spilling past
        // the segment edge (which previously clipped "Mbps" to "Mbp").
        if measured.width > cellWidth, measured.width > 0 {
            let ratio = cellWidth / measured.width
            let smaller = NSFont.monospacedDigitSystemFont(
                ofSize: 11 * max(ratio, 0.62), weight: .medium)
            value = NSAttributedString(string: text, attributes: [
                .font: smaller, .foregroundColor: ink(1, connected: connected)
            ])
            measured = value.size()
        }
        // Right-align inside the fixed cell: the number grows leftwards, so the trailing
        // edge of the menu-bar item never moves.
        let x = cellX + max(0, cellWidth - measured.width)
        value.draw(at: NSPoint(x: x, y: (height - measured.height) / 2))
    }
}

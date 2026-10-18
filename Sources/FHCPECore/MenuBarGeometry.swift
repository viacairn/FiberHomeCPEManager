import Foundation

/// Menu-bar segment geometry, shared by the renderer and the tests.
///
/// These constants live in the core module (which has no AppKit/SwiftUI dependency) so the
/// test target can assert the *real* numbers instead of a hand-copied duplicate. An earlier
/// copy drifted out of sync with the renderer, which is how the menu-bar width regression
/// went unnoticed.
///
/// Grid rule: every value is a multiple of 0.5 pt. The segment is rasterised at the display
/// scale factor, so a 0.4 pt offset lands on a fractional device pixel and makes otherwise
/// identical bars render with different edge softness (measured alpha `238/93`, `255/204`,
/// `255/153`, `255/51` along one scanline).
public enum MenuBarGeometry {
    /// Height of the segment. The menu bar is 22 pt tall, so 18 pt leaves native padding.
    public static let height: CGFloat = 18

    public static let barCount = 4
    /// Bars are slightly wider and taller than the first version so the glyph reads as
    /// "full" at menu-bar size, while staying inside the 18 pt canvas (12 pt tall, 3 pt
    /// inset top and bottom, so it is centred on the middle line rather than bottom-heavy).
    public static let barWidth: CGFloat = 3
    public static let barGap: CGFloat = 1.5
    /// Bars fill their cell exactly, so the first bar starts at x = 0.
    public static var barsWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
    }
    /// Tallest bar; shorter bars are fractions of it, giving the 1:2:3:4 progression.
    public static let maxBarHeight: CGFloat = 12
    /// Vertical inset that centers the tallest bar in the segment.
    public static var barTop: CGFloat { (height - maxBarHeight) / 2 }

    /// Gap between the bars and the numeric cell.
    public static let gap: CGFloat = 4
    /// Measured widest reading at 11 pt medium monospaced digits ("5.76 Mbps") is ≈57.8 pt;
    /// reserving 58 pt means no legal string is ever shrunk or clipped.
    public static let numberWidth: CGFloat = 58

    public static var payloadWidth: CGFloat { barsWidth + gap + numberWidth }

    /// Reserved width per display style. Independent of any reading, which is what keeps the
    /// menu-bar item from resizing on every refresh.
    public static func width(for style: MenuBarStyle) -> CGFloat {
        switch style {
        case .signalOnly: barsWidth
        case .signalAndRate: payloadWidth
        }
    }

    /// Horizontal origin of every bar in the segment.
    public static func barOrigin(_ index: Int) -> CGFloat {
        CGFloat(index) * (barWidth + barGap)
    }

    /// Height of a single bar for the 1:2:3:4 progression.
    public static func barHeight(_ index: Int) -> CGFloat {
        maxBarHeight * CGFloat(index + 1) / CGFloat(barCount)
    }

    /// The five signal states the menu-bar glyph must distinguish.
    ///
    /// This lives in the core module (rather than in the renderer) so the mapping from a
    /// device reading to a visual state can be unit-tested. Previously "unknown" and "zero
    /// bars" were rendered with 0.22 vs 0.26 alpha — a 4% difference that is invisible, so a
    /// disconnected app looked like it had signal.
    public enum SignalState: Equatable {
        /// No sample yet (disconnected, or first launch).
        case unknown
        /// A real reading with no bars.
        case none
        /// One to four bars.
        case bars(Int)

        public init(_ level: Int?) {
            guard let level else { self = .unknown; return }
            let clamped = max(0, min(MenuBarGeometry.barCount, level))
            self = clamped == 0 ? .none : .bars(clamped)
        }

        /// Number of solid bars to draw (0 for both unknown and none).
        public var filledCount: Int {
            if case .bars(let count) = self { return count }
            return 0
        }

        /// Whether the bars should be drawn hollow rather than filled.
        public var isHollow: Bool { self == .unknown }
    }

    /// Every horizontal/vertical quantity that must sit on the half-point grid.
    public static var gridValues: [CGFloat] {
        [height, barWidth, barGap, barsWidth, maxBarHeight, barTop, gap,
         numberWidth, payloadWidth,
         width(for: .signalOnly), width(for: .signalAndRate)]
            + (0..<barCount).flatMap { [barOrigin($0), barHeight($0)] }
    }
}

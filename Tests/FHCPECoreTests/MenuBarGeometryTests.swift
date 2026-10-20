import Testing
import Foundation
@testable import FHCPECore

/// Menu-bar geometry and signal-state regressions.
///
/// Three defects motivated these tests, all of them visible to the user:
/// 1. The segment width changed with the reading (74 → 103 pt).
/// 2. Bar coordinates sat on fractional points, so at 2x the four bars rendered with
///    different edge softness (measured alpha `238/93`, `255/204`, `255/153`, `255/51`).
/// 3. "Unknown" and "zero bars" differed by 4% alpha, making a disconnected app look as if
///    it had signal.
struct MenuBarGeometryTests {
    @Test func compactStatusSlotPreservesSignalAndRateArtwork() {
        #expect(MenuBarGeometry.statusItemWidth(for: .signalOnly) == 22.5)
        #expect(MenuBarGeometry.statusItemWidth(for: .signalAndRate) == 84.5)
        #expect(MenuBarGeometry.width(for: .signalOnly) == 16.5)
        #expect(MenuBarGeometry.numberWidth == 58)
    }

    /// A half-point grid guarantees integer device pixels at 2x; anything else blurs.
    @Test func everyCoordinateSitsOnTheHalfPointGrid() {
        for value in MenuBarGeometry.gridValues {
            let doubled = value * 2
            #expect(abs(doubled - doubled.rounded()) < 0.0001,
                    "\(value) pt is not a multiple of 0.5 pt")
        }
    }

    /// Bars must fill their cell exactly, otherwise the first bar starts at a sub-pixel x.
    @Test func barsFillTheirCellExactly() {
        let expected = CGFloat(MenuBarGeometry.barCount) * MenuBarGeometry.barWidth
            + CGFloat(MenuBarGeometry.barCount - 1) * MenuBarGeometry.barGap
        #expect(MenuBarGeometry.barsWidth == expected)
        #expect(MenuBarGeometry.barOrigin(0) == 0)
        // The last bar's right edge is the cell's right edge.
        let lastRight = MenuBarGeometry.barOrigin(MenuBarGeometry.barCount - 1)
            + MenuBarGeometry.barWidth
        #expect(lastRight == MenuBarGeometry.barsWidth)
    }

    /// There are exactly two display modes: signal, or signal + rate. An icon-only mode was
    /// removed because it hid the signal, which is the item's whole purpose.
    @Test func onlyTwoDisplayModesExist() {
        #expect(MenuBarStyle.allCases == [.signalAndRate, .signalOnly])
        // Signal-only is the product default; the rate readout is opt-in.
        #expect(MenuBarStyle.default == .signalOnly)
        // A value stored by an older build (which had icon-only = 2) falls back safely.
        #expect(MenuBarStyle.stored(2) == .signalOnly)
        #expect(MenuBarStyle.stored(1) == .signalOnly)
        #expect(MenuBarStyle.stored(0) == .signalAndRate)
    }

    /// The four bars form a 1:2:3:4 progression.
    @Test func barsFollowTheDesignProgression() {
        let heights = (0..<MenuBarGeometry.barCount).map(MenuBarGeometry.barHeight)
        #expect(heights == [3, 6, 9, 12])
    }

    /// Each style reserves exactly one width, independent of what the device reports.
    @Test func widthsDependOnStyleOnly() {
        #expect(MenuBarGeometry.barsWidth == 16.5)
        #expect(MenuBarGeometry.width(for: .signalOnly) == 16.5)
        #expect(MenuBarGeometry.width(for: .signalAndRate) == 78.5)
        // The rate cell makes the wider style strictly wider.
        #expect(MenuBarGeometry.width(for: .signalOnly)
                < MenuBarGeometry.width(for: .signalAndRate))
    }

    /// The numeric cell must be at least as wide as the widest measured reading (57.8 pt),
    /// which was the cause of "Mbps" being clipped to "Mbp".
    @Test func numericCellFitsTheWidestReading() {
        #expect(MenuBarGeometry.numberWidth >= 58)
    }

    /// Reading → visual state mapping for every value the device can produce.
    @Test func signalStateMapping() {
        #expect(MenuBarGeometry.SignalState(nil) == .unknown)
        #expect(MenuBarGeometry.SignalState(0) == .none)
        #expect(MenuBarGeometry.SignalState(1) == .bars(1))
        #expect(MenuBarGeometry.SignalState(4) == .bars(4))
        // Out-of-range readings clamp instead of crashing or drawing nothing.
        #expect(MenuBarGeometry.SignalState(9) == .bars(4))
        #expect(MenuBarGeometry.SignalState(-3) == .none)
    }

    /// Unknown must be renderable differently from "no bars", or the two look identical.
    @Test func unknownIsDistinctFromNoSignal() {
        #expect(MenuBarGeometry.SignalState(nil).isHollow)
        #expect(!MenuBarGeometry.SignalState(0).isHollow)
        #expect(!MenuBarGeometry.SignalState(2).isHollow)
        #expect(MenuBarGeometry.SignalState(nil) != MenuBarGeometry.SignalState(0))
    }

    /// Filled count drives how many solid bars are drawn.
    @Test func filledCountMatchesTheReading() {
        #expect(MenuBarGeometry.SignalState(nil).filledCount == 0)
        #expect(MenuBarGeometry.SignalState(0).filledCount == 0)
        for level in 1...4 {
            #expect(MenuBarGeometry.SignalState(level).filledCount == level)
        }
    }
}

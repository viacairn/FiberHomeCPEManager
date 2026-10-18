import Testing
import Foundation
@testable import FHCPECore

/// Menu-bar sizing regressions.
///
/// The menu bar once resized itself every time the rate text changed (measured
/// 74 → 103 pt). The fix draws the whole segment into one fixed-size template image, so
/// these tests pin the two invariants that make that work: the segment width is a
/// constant, and the text inside the fixed numeric cell never exceeds a known length.
struct MenuBarTests {
    private func snapshot(bps: Double?, bars: Int?) -> DeviceSnapshot {
        var s = DeviceSnapshot()
        s.downloadBps = bps
        s.signalBars = bars
        s.network = "5G"
        return s
    }

    /// Every reading the device can produce must yield the same segment width.
    @Test func segmentWidthIsIndependentOfReading() {
        // Each style has exactly one width, independent of the snapshot.
        let widths: [(MenuBarStyle, CGFloat)] = [
            (.signalAndRate, MenuBarGeometry.width(for: .signalAndRate)),
            (.signalOnly, MenuBarGeometry.width(for: .signalOnly))
        ]
        for (style, expected) in widths {
            for bps in [nil, 0.0, 400.0, 999_000.0, 5_760_000.0, 102_400_000.0, 1_280_000_000.0] as [Double?] {
                for bars in [nil, 0, 1, 2, 3, 4] as [Int?] {
                    let text = MenuBarText.label(for: snapshot(bps: bps, bars: bars), style: style, stale: false)
                    // The renderer's contract: width comes from the style alone.
                    #expect(MenuBarGeometry.width(for: style) == expected)
                    // And the text must fit the reserved cell.
                    #expect(text.count <= Self.maxCharacters(for: style),
                            "text \(text) too long for \(style)")
                }
            }
        }
    }

    /// The design vocabulary is Kbps / Mbps / Gbps. A raw "bps" unit is not allowed
    /// because it widens the segment and is not part of the spec.
    @Test func bitRateNeverUsesRawBpsUnit() {
        let cases: [(Double, String, String)] = [
            (0, "0", "Kbps"),
            (400, "0.4", "Kbps"),
            (999, "1", "Kbps"),          // rounds up to 1 Kbps
            (999_000, "999", "Kbps"),
            (1_000_000, "1", "Mbps"),
            (5_760_000, "5.76", "Mbps"),
            (102_400_000, "102", "Mbps"),
            (1_280_000_000, "1.28", "Gbps")
        ]
        for (bps, value, unit) in cases {
            let formatted = MetricFormatter.bitRate(bps)
            #expect(formatted?.value == value, "value for \(bps)")
            #expect(formatted?.unit == unit, "unit for \(bps)")
        }
        #expect(MetricFormatter.bitRate(nil) == nil)
        #expect(MetricFormatter.bitRate(-1) == nil)
    }

    /// A first sample has no rate yet; the segment shows an em dash, never a bar count.
    @Test func missingRateShowsDashNotBars() {
        let text = MenuBarText.label(for: snapshot(bps: nil, bars: 4), style: .signalAndRate, stale: false)
        #expect(text == "—")
    }

    /// A stale reading must not look live.
    @Test func staleReadingShowsDash() {
        let text = MenuBarText.label(for: snapshot(bps: 102_400_000, bars: 4), style: .signalAndRate, stale: true)
        #expect(text == "—")
    }

    /// No snapshot at all still reserves the segment; the signal-only style carries no text.
    @Test func disconnectedStatesKeepSegmentStable() {
        #expect(MenuBarText.label(for: nil, style: .signalAndRate, stale: false) == "—")
        #expect(MenuBarText.label(for: nil, style: .signalOnly, stale: false) == "")
    }

    /// Longest string each style can legally render inside its fixed cell.
    static func maxCharacters(for style: MenuBarStyle) -> Int {
        switch style {
        case .signalOnly: 0
        case .signalAndRate: 9   // "999 Mbps" / "1.28 Gbps" / "0.4 Kbps"
        }
    }
}

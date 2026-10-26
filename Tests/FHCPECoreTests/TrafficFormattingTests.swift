import Testing
@testable import FHCPECore

struct TrafficFormattingTests {
    @Test func trafficMatchesFirmware1024Prefixes() {
        // Synthetic byte counts; the stock WebUI uses binary divisors with KB/MB/GB labels.
        let cases: [(Double, String, String)] = [
            (0, "0", "B"),
            (1_000, "1000", "B"),
            (1_024, "1", "KB"),
            (1_048_576, "1", "MB"),
            (1_073_741_824, "1", "GB"),
            (107_374_182_400, "100", "GB"),
            (1_099_511_627_776, "1", "TB")
        ]
        for (bytes, value, unit) in cases {
            let formatted = MetricFormatter.bytes(bytes)
            #expect(formatted?.value == value, "value for \(bytes) bytes")
            #expect(formatted?.unit == unit, "unit for \(bytes) bytes")
        }
    }

    @Test func roundingPromotesAt1024InsteadOf1000() {
        let cases: [(Double, String, String)] = [
            (1_024_000, "1000", "KB"),
            (1_048_576_000, "1000", "MB"),
            (1_073_741_824_000, "1000", "GB"),
            (1_073_741_823, "1", "GB")
        ]
        for (bytes, value, unit) in cases {
            let formatted = MetricFormatter.bytes(bytes)
            #expect(formatted?.value == value)
            #expect(formatted?.unit == unit)
        }
    }

    @Test func unavailableTrafficStaysMissing() {
        for bytes: Double? in [nil, -1, .nan, .infinity, -.infinity] {
            #expect(MetricFormatter.bytes(bytes) == nil)
        }
    }

    @Test func networkBitRatesRetainDecimalPrefixes() {
        let formatted = MetricFormatter.bitRate(1_000_000_000)
        #expect(formatted?.value == "1")
        #expect(formatted?.unit == "Gbps")
    }
}

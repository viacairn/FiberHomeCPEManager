import Testing
@testable import FHCPECore

/// Registration state in the overview hero card.
struct ReadinessTests {
    @Test func registeredWhenUplinkWorks() {
        #expect(Readiness.derive(uplinkAvailable: true, signalBars: 0) == .registered)
        #expect(Readiness.derive(uplinkAvailable: true, signalBars: nil) == .registered)
    }

    /// A visible cell without a usable uplink is "searching", not "not ready".
    @Test func searchingWhenCellVisible() {
        #expect(Readiness.derive(uplinkAvailable: false, signalBars: 3) == .searching)
        #expect(Readiness.derive(uplinkAvailable: false, signalBars: 1) == .searching)
    }

    @Test func notReadyWithoutSignal() {
        #expect(Readiness.derive(uplinkAvailable: false, signalBars: 0) == .notReady)
        #expect(Readiness.derive(uplinkAvailable: false, signalBars: nil) == .notReady)
    }

    @Test func titles() {
        #expect(Readiness.registered.title == "已注册")
        #expect(Readiness.searching.title == "搜索中")
        #expect(Readiness.notReady.title == "未就绪")
    }
}

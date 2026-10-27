import Testing
@testable import FHCPECore
@testable import FHCPEMUI

/// Page presentation must reject retained readings as soon as the session loses live evidence.
struct PageDataTests {
    @Test func disconnectedReadingHidesSnapshotAndDerivedValues() {
        let data = PageData(snapshot: previousReading(), connected: false)

        #expect(!data.isLive)
        #expect(data.snapshot == nil)
        #expect(data.snapshot?.temperature == nil)
        #expect(data.radio == RadioReading())
        #expect(!data.isNR)
        #expect(data.model == "待连接")
        #expect(data.network == "—")
        #expect(data.uplink == .unknown)
        #expect(data.signalBars == nil)
        #expect(data.wanAddress == nil)
        #expect(data.ethernetAddress == nil)
        #expect(data.uptimeText == nil)
        #expect(data.smsCount == nil)
        #expect(!data.hasCellularSignal)
    }

    @Test func staleReadingHidesSnapshotAndDerivedValues() {
        let data = PageData(snapshot: previousReading(), stale: true, connected: true)

        #expect(!data.isLive)
        #expect(data.snapshot == nil)
        #expect(data.radio == RadioReading())
        #expect(!data.isNR)
        #expect(data.model == "待连接")
        #expect(data.uplink == .unknown)
        #expect(!data.uplinkAvailable)
        #expect(!data.cellularConnected)
        #expect(!data.ethernetConnected)
    }

    @Test func disconnectMasksReadingsAlreadyHeldOrAssignedLater() {
        var data = PageData(snapshot: previousReading(), connected: true)
        #expect(data.snapshot?.temperature == "48")
        #expect(data.radio.plmn == "46001")

        data.connected = false
        #expect(data.snapshot == nil)
        #expect(data.radio.plmn == nil)

        var delayedReading = previousReading()
        delayedReading.temperature = "52"
        delayedReading.nr.plmn = "46011"
        data.snapshot = delayedReading

        #expect(data.snapshot == nil)
        #expect(data.radio.plmn == nil)
        #expect(data.model == "待连接")
    }

    @Test func markingAnExistingReadingStaleHidesItImmediately() {
        var data = PageData(snapshot: previousReading(), connected: true)
        #expect(data.isNR)
        #expect(data.uplink == .cellular)

        data.stale = true

        #expect(data.snapshot == nil)
        #expect(data.radio == RadioReading())
        #expect(!data.isNR)
        #expect(data.uplink == .unknown)
    }

    @Test func liveReadingKeepsMeasuredZeroDistinctFromMissingRate() {
        var reading = previousReading()
        reading.uploadBps = 0
        reading.downloadBps = nil
        let data = PageData(snapshot: reading, connected: true)

        #expect(data.isLive)
        #expect(data.model == "LG6851F")
        #expect(data.radio.plmn == "46001")
        #expect(data.isNR)
        #expect(data.snapshot?.temperature == "48")
        #expect(data.snapshot?.uploadBps == 0)
        #expect(MetricFormatter.bitRate(data.snapshot?.uploadBps)?.value == "0")
        #expect(MetricFormatter.bitRate(data.snapshot?.uploadBps)?.unit == "Kbps")
        #expect(data.snapshot?.downloadBps == nil)
        #expect(MetricFormatter.bitRate(data.snapshot?.downloadBps) == nil)
    }

    @Test func offlineDeviceListsStayHiddenAfterLaterAssignments() {
        let device = ConnectedDevice(id: "client-1", name: "Mac", ip: "192.168.8.20", access: .wifi5G)
        var data = PageData(snapshot: previousReading(), devices: [device], connected: true)
        #expect(data.devices.count == 1)
        #expect(data.deviceCount == 1)

        data.connected = false
        #expect(data.devices.isEmpty)
        #expect(data.deviceCount == nil)

        data.devices = [device]
        #expect(data.devices.isEmpty)

        let staleData = PageData(snapshot: previousReading(), devices: [device], stale: true, connected: true)
        #expect(staleData.devices.isEmpty)
    }

    @Test(arguments: [("59", "0 分钟"), ("900", "15 分钟"), ("3660", "1 小时 1 分"),
                      ("90000", "1 天 1 小时")])
    func uptimeUsesSharedDurationFormattingWithExistingMinuteWording(seconds: String, expected: String) {
        var reading = previousReading()
        reading.uptime = seconds
        #expect(PageData(snapshot: reading, connected: true).uptimeText == expected)
    }

    private func previousReading() -> DeviceSnapshot {
        var reading = DeviceSnapshot()
        reading.model = "LG6851F"
        reading.network = "5G"
        reading.activeTech = .nr
        reading.nr.plmn = "46001"
        reading.nr.rsrp = "-86"
        reading.nr.band = "n78"
        reading.temperature = "48"
        reading.uplink = .cellular
        reading.uplinkAvailable = true
        reading.wanConnected = true
        reading.wanAddress = "198.51.100.20"
        reading.ethernetConnected = true
        reading.ethernetAddress = "192.0.2.20"
        reading.signalBars = 4
        reading.uptime = "3600"
        reading.smsCount = 2
        reading.uploadBps = 1_000_000
        reading.downloadBps = 5_000_000
        return reading
    }
}

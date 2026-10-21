import Testing
import Foundation
@testable import FHCPECore

/// End-to-end checks against a local stand-in for the device console.
///
/// These never touch the real router and never read a Keychain item: the fake server only
/// accepts the literal test password. Its responses reproduce the quirks observed on the
/// RP0112 protocol contract, so a regression in
/// parsing shows up here instead of on the user's network.
@Suite(.serialized)
struct EndToEndTests {
    @Test func unavailableHeartbeatDoesNotBlockProtectedSampling() async throws {
        try await withServer { server, port in
            server.disableHeartbeat()
            let session = DeviceSession(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            let connected = try await session.connect(username: "admin", password: "test-password")
            #expect(connected.snapshot.model == "LG6851F")
            _ = try await session.refresh()
            #expect(server.log.filter { $0 == "HEARTBEAT" }.count == 1)
            server.expireSession()
            await #expect(throws: CPEError.authentication) { _ = try await session.refresh() }
            await session.close()
        }
    }

    @Test func heartbeatUsesCurrentLoginAndRejectsExpiredSession() async throws {
        try await withServer { server, port in
            let transport = LocalTransport(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            await #expect(throws: CPEError.authentication) { try await transport.keepAlive() }
            #expect(!server.log.contains("REFRESH_TIMEOUT"))
            try await LG6851Adapter(rpc: transport).login(username: "admin", password: "test-password")
            try await transport.keepAlive()
            #expect(Array(server.log.suffix(2)) == ["HEARTBEAT", "REFRESH_TIMEOUT"])
            server.expireSession()
            await #expect(throws: CPEError.authentication) { try await transport.keepAlive() }
            #expect(server.log.filter { $0 == "REFRESH_TIMEOUT" }.count == 1)
            await transport.close()
        }
    }

    @Test func firmwareWithoutActivityEndpointKeepsCheckingAuthentication() async throws {
        try await withServer { server, port in
            server.disableActivityRenewal()
            let transport = LocalTransport(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            try await LG6851Adapter(rpc: transport).login(username: "admin", password: "test-password")
            try await transport.keepAlive()
            try await transport.keepAlive()
            #expect(server.log.filter { $0 == "HEARTBEAT" }.count == 2)
            #expect(server.log.filter { $0 == "REFRESH_TIMEOUT" }.count == 1)
            server.expireSession()
            await #expect(throws: CPEError.authentication) { try await transport.keepAlive() }
            await transport.close()
        }
    }

    @Test func loginStartsHeartbeatAndFrequentSamplesDoNotSpamIt() async throws {
        try await withServer { server, port in
            let session = DeviceSession(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            _ = try await session.connect(username: "admin", password: "test-password")
            #expect(server.log.filter { $0 == "HEARTBEAT" }.count == 1)
            #expect(server.log.filter { $0 == "REFRESH_TIMEOUT" }.count == 1)
            for _ in 0..<3 { _ = try await session.refresh() }
            #expect(server.log.filter { $0 == "HEARTBEAT" }.count == 1)
            #expect(server.log.filter { $0 == "REFRESH_TIMEOUT" }.count == 1)
            await session.close()
        }
    }

    @Test func displacedLoginRequiresAuthenticationForSnapshotAndSMS() async throws {
        try await withServer { server, port in
            let session = DeviceSession(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            _ = try await session.connect(username: "admin", password: "test-password")
            server.expireSession()
            await #expect(throws: CPEError.authentication) { _ = try await session.refresh() }
            await #expect(throws: CPEError.authentication) { _ = try await session.threads() }
            await session.close()
        }
    }
    private func withServer<T>(_ body: (FakeCPE, UInt16) async throws -> T) async throws -> T {
        let server = try FakeCPE()
        let port = try server.start()
        defer { server.stop() }
        do {
            return try await body(server, port)
        } catch {
            Issue.record("server call failed on port \(port): \(error); events=\(server.log)")
            throw error
        }
    }

    @Test func loginRejectsWrongPassword() async throws {
        try await withServer { _, port in
            let session = DeviceSession(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            await #expect(throws: CPEError.self) {
                _ = try await session.connect(username: "admin", password: "wrong")
            }
            await session.close()
        }
    }

    @Test func loginAndSnapshotParseFirmwareFields() async throws {
        try await withServer { _, port in
            let session = DeviceSession(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            let reading = try await session.connect(username: "admin", password: "test-password")
            let s = reading.snapshot

            #expect(s.model == "LG6851F")
            #expect(s.firmware == "RP0112")
            #expect(s.manufacturer == "FiberHome")

            // WorkMode is the architecture ("SA"), so the RAT comes from the NR band.
            #expect(s.activeTech == .nr)
            #expect(s.network == "5G")
            #expect(s.nrMode == "SA")
            #expect(s.nr.band == "n78")
            #expect(s.nr.pci == "101")
            #expect(s.nr.cell == "70000000001")
            #expect(s.nr.rsrp == "-83")
            #expect(s.nr.sinr == "7")
            // Comma-separated firmware values must be reduced to one value.
            #expect(s.nr.arfcn == "634464")
            #expect(s.nr.qci == "8")
            #expect(s.nr.dlAmbrKbps == 512000)

            // LTE is not attached: the empty band must suppress the stale PCI/zeros.
            #expect(s.lte.band == nil)
            #expect(s.lte.rsrp == nil)

            // Signal bars come straight from Signal_Level on this firmware.
            #expect(s.signalBars == 4)
            // Temperature arrives in thousandths of a degree.
            #expect(s.temperature == "31.7")

            // Uplink usability is proven by WAN state, not by SIM flags (both are 0).
            #expect(s.wanConnected)
            #expect(s.uplinkAvailable)
            #expect(s.uplink == .cellular)
            #expect(s.wanAddress == "198.51.100.20")

            #expect(s.todayBytes == 9_420_000_000)
            #expect(s.monthBytes == 126_800_000_000)
            #expect(s.smsCount == 26)
            #expect(s.cells.map(\.pci) == ["101", "102", "103"])
            #expect(s.cells.map(\.state) == [.serving, .neighbor, .neighbor])

            // Inactive historical hosts are filtered; DevName wins over HostName.
            #expect(reading.devices.count == 3)
            let names = Set(reading.devices.map(\.name))
            #expect(names == ["iPad", "Demo-Device-7c09e0", "Demo-Device-495f4d"])
            let vacuum = reading.devices.first { $0.name == "Demo-Device-7c09e0" }
            #expect(vacuum?.access == .wifi24G)
            #expect(vacuum?.ip == "192.168.8.100")
            let ipad = reading.devices.first { $0.name == "iPad" }
            #expect(ipad?.access == .wifi5G)
            let wired = reading.devices.first { $0.name == "Demo-Device-495f4d" }
            #expect(wired?.access == .wired)

            await session.close()
        }
    }

    /// The byte-counter fallback keeps its original semantics.
    ///
    /// The first call has no baseline and must report nothing (nil) rather than a fake zero;
    /// a genuinely unchanged counter is a real zero. The live `Speed*Bytes` fields take
    /// priority over this path — see `liveSpeedCountersDriveTheRateImmediately`.
    @Test func counterDeltaNeedsABaselineAndReportsRealZero() {
        var counter = TrafficCounter()
        #expect(counter.update(bytes: 8_000_000, time: 100) == nil, "first sample has no baseline")
        #expect(counter.update(bytes: 8_000_000, time: 102) == 0, "unchanged counter is a real zero")
        // 2 MB over 2 s = 1 MB/s.
        #expect(counter.update(bytes: 10_000_000, time: 104) == 1_000_000)
        // A counter reset must not produce a negative rate.
        #expect(counter.update(bytes: 5, time: 106) == nil)
        #expect(MetricFormatter.bitRate(0)?.value == "0")
    }

    /// The firmware's instantaneous speed fields must drive the rate.
    ///
    /// The daily totals (`TodayTotal*`) refresh only every few seconds, so a byte-delta on
    /// them reported 0 Kbps during a real 60 MB download. `SpeedRxBytes` / `SpeedTxBytes`
    /// update on every poll, and are in bytes per second.
    @Test func liveSpeedCountersDriveTheRateImmediately() async throws {
        try await withServer { _, port in
            let session = DeviceSession(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            let first = try await session.connect(username: "admin", password: "test-password")
            // 1_250_000 B/s × 8 = 10 Mbps, available on the very first sample.
            #expect(first.snapshot.downloadBps == 10_000_000)
            // 250_000 B/s × 8 = 2 Mbps.
            #expect(first.snapshot.uploadBps == 2_000_000)
            let second = try await session.refresh()
            #expect(second.snapshot.downloadBps == 10_000_000)
            await session.close()
        }
    }

    /// SMS conversations come from `get_sms_data`, grouped by remote number.
    ///
    /// The previous implementation guessed per-field xmlnode names (`From`, `Content`,
    /// `ReceivedTime`), which this firmware never returns — the inbox looked empty while the
    /// device held 26 messages.
    @Test func smsThreadsGroupByNumberAndSortByTime() async throws {
        try await withServer { _, port in
            let session = DeviceSession(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            _ = try await session.connect(username: "admin", password: "test-password")
            let threads = try await session.threads()
            #expect(threads.count == 1)
            let thread = try #require(threads.first)
            #expect(thread.phone == "10010")
            #expect(thread.messages.count == 2)
            // The firmware returns items out of order; the UI needs chronological order.
            #expect(thread.messages.map(\.body) == ["合成测试通知 714c：演示套餐剩余 42 GB，仅用于界面与测试。", "第二条：积分提醒"])
            #expect(thread.unreadCount == 1)
            #expect(thread.preview.contains("积分提醒"))
            await session.close()
        }
    }

    @Test func protectedReadRejectedBeforeLogin() async throws {
        try await withServer { _, port in
            let transport = LocalTransport(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            _ = try await transport.call("get_device_info", data: .null, publicAccess: true)
            await #expect(throws: CPEError.self) {
                _ = try await transport.call("get_value_by_xmlnode",
                                             data: .strings(["m": "DeviceInfo.ModelName"]),
                                             publicAccess: false)
            }
            await transport.close()
        }
    }

    @Test func neighbourArraysBecomeIndexAlignedCells() async throws {
        try await withServer { _, port in
            let transport = LocalTransport(address: try DeviceAddress("http://127.0.0.1:\(port)"))
            _ = try await transport.call("get_device_info", data: .null, publicAccess: true)
            _ = try await transport.call("DO_WEB_LOGIN",
                                         data: .strings(["username": "admin", "password": "test-password"]),
                                         publicAccess: true)
            let cells = try await LG6851ExtendedAdapter(rpc: transport).discoverableCells()
            #expect(cells.count == 3)
            #expect(cells.first?.state == .serving)
            #expect(cells.first?.pci == "101")
            #expect(cells.first?.band == "N78")
            #expect(cells.first?.rsrp == "-83")
            #expect(cells.map(\.state) == [.serving, .neighbor, .neighbor])
            #expect(cells.map(\.pci) == ["101", "102", "103"])
            await transport.close()
        }
    }
}

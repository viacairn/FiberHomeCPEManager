import Testing
@testable import FHCPECore

/// Uplink switching: what each mode writes and how success is judged.
struct UplinkTargetTests {
    @Test func cellularSelectsTheCellularWANAndTurnsAggregationOff() {
        let writes = UplinkTarget.cellular.writes()
        #expect(writes.count == 2)
        #expect(writes[0].path == "DeviceInfo.X_FH_CurrentWANDevice")
        #expect(writes[0].value == "InternetGatewayDevice.WANDevice.1.")
        #expect(writes[1].path == "DeviceInfo.X_FH_Multiwan_Aggregation.Enable")
        #expect(writes[1].value == "0")
    }

    @Test func ethernetSelectsTheSecondWAN() {
        let writes = UplinkTarget.ethernet.writes()
        #expect(writes[0].value == "InternetGatewayDevice.WANDevice.2.")
        #expect(writes[1].value == "0")
    }

    /// Aggregation is a flag, not a device: it must not rewrite the active WAN.
    @Test func aggregationOnlyFlipsTheFlag() {
        let writes = UplinkTarget.aggregation.writes()
        #expect(writes.count == 1)
        #expect(writes[0].path == "DeviceInfo.X_FH_Multiwan_Aggregation.Enable")
        #expect(writes[0].value == "1")
    }

    /// The two failover modes stay inert until the stock submit payload is captured.
    @Test func failoverModesArePendingAndWriteNothing() {
        #expect(UplinkTarget.cellularPreferred.isSupported == false)
        #expect(UplinkTarget.ethernetPreferred.isSupported == false)
        #expect(UplinkTarget.cellularPreferred.writes().isEmpty)
        #expect(UplinkTarget.ethernetPreferred.writes().isEmpty)
        #expect(UplinkTarget.cellular.isSupported)
        #expect(UplinkTarget.ethernet.isSupported)
        #expect(UplinkTarget.aggregation.isSupported)
        #expect(UplinkTarget.allCases.map(\.webValue) == [
            "dev.5G.1_1", "dev.eth.1_2", "nb5g,lan1", "lan1,nb5g", "aggregation"
        ])
    }

    @Test func successfulReceiptsDoNotNeedAMatchingReadback() async throws {
        for target in [UplinkTarget.cellular, .ethernet, .aggregation] {
            let rpc = RecordingRPC()
            #expect(try await SettingsService(rpc: rpc).setUplink(target))
            #expect(rpc.calls.count == target.writes().count)
            #expect(rpc.calls.allSatisfy { $0.method == "set_single_by_xmlnode" })
        }
    }

    @Test func activeModeIsDerivedFromTheDevice() {
        var settings = DeviceSettings()
        settings.currentWANDevice = "InternetGatewayDevice.WANDevice.1."
        #expect(settings.activeUplink == .cellular)
        settings.currentWANDevice = "InternetGatewayDevice.WANDevice.2."
        #expect(settings.activeUplink == .ethernet)
        settings.aggregationEnabled = true
        #expect(settings.activeUplink == .aggregation)
    }
}

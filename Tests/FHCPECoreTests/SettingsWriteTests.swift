import Testing
import Foundation
@testable import FHCPECore

/// Records RPC calls so the settings write contract can be asserted without a device.
final class RecordingRPC: DeviceRPC, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, data: JSONValue)] = []
    var reply: JSONValue = .object(["success": .string("true")])

    var calls: [(method: String, data: JSONValue)] {
        lock.withLock { recorded }
    }

    func call(_ method: String, data: JSONValue, publicAccess: Bool) async throws -> JSONValue {
        lock.withLock { recorded.append((method, data)) }
        return reply
    }
}

/// The firmware's write API was only discovered by capturing the device's own web UI.
///
/// It is `set_single_by_xmlnode` with two plain strings — `{url, value}` — not the
/// multi-node `set_value_by_xmlnode` map form, which answers `ERRORSTATUS: 400` for the
/// same node. These tests pin that shape so a future refactor cannot silently break writes.
struct SettingsWriteTests {
    @Test func ledWriteUsesSingleNodeMethodAndPrefixedPath() async throws {
        let rpc = RecordingRPC()
        _ = try await SettingsService(rpc: rpc).setLEDEnabled(true)
        let call = try #require(rpc.calls.first)
        #expect(call.method == "set_single_by_xmlnode")
        #expect(call.data["url"].text == "DeviceInfo.X_FH_LedControl.Switch")
        #expect(call.data["value"].text == "1")
        // Crucially not the map form that the device rejects.
        #expect(call.data["url"].objectPairs.isEmpty)
    }

    @Test func disablingTheLEDWritesZero() async throws {
        let rpc = RecordingRPC()
        _ = try await SettingsService(rpc: rpc).setLEDEnabled(false)
        #expect(rpc.calls.first?.data["value"].text == "0")
    }

    @Test func ssidEnableWritesTheIndexedPath() async throws {
        let rpc = RecordingRPC()
        _ = try await SettingsService(rpc: rpc).setSSIDEnabled(index: 5, enabled: true)
        #expect(rpc.calls.first?.method == "set_single_by_xmlnode")
        #expect(rpc.calls.first?.data["url"].text == "WiFi.SSID.5.Enable")
        #expect(rpc.calls.first?.data["value"].text == "1")
    }

    @Test func timedRebootWritesAllThreeNodes() async throws {
        let rpc = RecordingRPC()
        _ = try await SettingsService(rpc: rpc).setTimedReboot(enabled: true, time: "04:30",
                                                               weekday: "Sunday")
        let urls = rpc.calls.compactMap { $0.data["url"].text }
        #expect(urls == ["DeviceInfo.TimedReboot.1.enable",
                         "DeviceInfo.TimedReboot.1.time",
                         "DeviceInfo.TimedReboot.1.week_of_day"])
        #expect(rpc.calls.map { $0.data["value"].text } == ["1", "04:30", "Sunday"])
    }

    /// A firmware that answers without `success` is treated as the older `result` style.
    @Test func legacyResultReplyIsAccepted() async throws {
        let rpc = RecordingRPC()
        rpc.reply = .object(["result": .string("0")])
        #expect(try await SettingsService(rpc: rpc).setLEDEnabled(true))
    }

    @Test func rejectedReplyReportsFailure() async throws {
        let rpc = RecordingRPC()
        rpc.reply = .object(["success": .string("false")])
        #expect(try await SettingsService(rpc: rpc).setLEDEnabled(true) == false)
    }

    @Test func markReadUsesSingleNodeWrites() async throws {
        let rpc = RecordingRPC()
        try await LG6851ExtendedAdapter(rpc: rpc).markRead(childnodes: ["1", "2"])
        #expect(rpc.calls.count == 2)
        #expect(rpc.calls.allSatisfy { $0.method == "set_single_by_xmlnode" })
        #expect(rpc.calls.map { $0.data["url"].text } == [
            "InternetGatewayDevice.X_FH_MobileNetwork.SMS_Recv.SMS_RecvMsg.1.isOpened",
            "InternetGatewayDevice.X_FH_MobileNetwork.SMS_Recv.SMS_RecvMsg.2.isOpened"
        ])
        #expect(rpc.calls.map { $0.data["value"].text } == ["1", "1"])
    }

    @Test func lockBackendUsesSingleNodeWrites() async throws {
        let rpc = RecordingRPC()
        let backend = LG6851LockBackend(rpc: rpc)
        try await backend.apply(.bands(lte: [3], nr: [78]))
        #expect(rpc.calls.count == 3)
        #expect(rpc.calls.allSatisfy { $0.method == "set_single_by_xmlnode" })
        #expect(rpc.calls.map { $0.data["url"].text } == [
            "X_FH_MobileNetwork.NetworkSettings.LTELockBAND",
            "X_FH_MobileNetwork.NetworkSettings.LockBandEnable",
            "X_FH_MobileNetwork.NetworkSettings.NRLockBAND"
        ])
    }

    @Test func settingsReadBatchesRequestsInsteadOfSequentialLoops() async throws {
        let rpc = RecordingRPC()
        rpc.reply = .object([
            "r1band": .string("2.4GHz"),
            "r2band": .string("5GHz"),
            "ssid1_name": .string("Home-2.4G"),
            "ssid1_en": .string("1"),
            "ssid1_low": .string("Device.WiFi.Radio.1"),
            "ssid5_name": .string("Home-5G"),
            "ssid5_en": .string("1"),
            "ssid5_low": .string("Device.WiFi.Radio.2"),
            "sec1": .string("WPA2-Personal"),
            "sec5": .string("WPA2-WPA3-Personal"),
            "led_on": .string("1"),
            "wan_device": .string(UplinkTarget.cellularDevice),
            "wan_agg": .string("0")
        ])
        let settings = try await SettingsService(rpc: rpc).read()
        // Only 3 batched get_value_by_xmlnode calls instead of 22 individual calls!
        #expect(rpc.calls.count == 3)
        #expect(settings.wifi.count == 2)
        #expect(settings.wifi.first?.ssid == "Home-2.4G")
        #expect(settings.wifi.first?.security == "WPA2-Personal")
        #expect(settings.wifi.last?.ssid == "Home-5G")
        #expect(settings.wifi.last?.security == "WPA2-WPA3-Personal")
    }

    @Test func parseCellsBuildsIndexAlignedServingAndNeighbourCells() {
        let cells = LG6851ExtendedAdapter.parseCells(
            servingBand: "78",
            servingPci: "101",
            servingRsrp: "-83",
            servingSinr: "7",
            servingArfcn: "634464,634464,634464",
            lteBand: "",
            pcis: "101,102,103",
            bands: "N78,N78,N78",
            rsrps: "-83,-89,-97",
            sinrs: "7,1,-8",
            arfcns: "634464,634464,634464"
        )
        #expect(cells.count == 3)
        #expect(cells.map(\.pci) == ["101", "102", "103"])
        #expect(cells.map(\.state) == [.serving, .neighbor, .neighbor])
    }

    @Test func fanModeEnumerationMatchesStockWebUI() {
        #expect(FanMode.standard.rawValue == "0")
        #expect(FanMode.silent.rawValue == "1")
        #expect(FanMode.performance.rawValue == "2")
        #expect(FanMode.standard.title == "标准模式")
        #expect(FanMode.silent.title == "静音模式")
        #expect(FanMode.performance.title == "性能模式")
    }

    @Test func parseLockedCellsDecodesLiveChildNodeShape() {
        let payload: JSONValue = .object([
            "data": .array([
                .object(["child_node_idx": .number(1), "act": .string("2"), "arfcn": .string("504990"), "pci": .string("524")]),
                .object(["child_node_idx": .number(2), "act": .string("2"), "arfcn": .string("152650"), "pci": .string("536")]),
                .object(["child_node_idx": .number(3), "act": .string("1"), "arfcn": .string("1850"), "pci": .string("108")])
            ])
        ])
        let cells = LG6851Adapter.parseLockedCells(payload)
        #expect(cells == [
            LockedCell(index: 1, act: 2, arfcn: 504990, pci: 524),
            LockedCell(index: 2, act: 2, arfcn: 152650, pci: 536),
            LockedCell(index: 3, act: 1, arfcn: 1850, pci: 108)
        ])
        #expect(cells[0].techTitle == "5G NR")
        #expect(cells[2].techTitle == "4G LTE")
    }

    @Test func cellLockBackendAddsCandidateAndEnablesSwitch() async throws {
        let rpc = RecordingRPC()
        let backend = LG6851LockBackend(rpc: rpc)
        try await backend.apply(.cell(rat: 2, arfcn: 634464, pci: 101))
        #expect(rpc.calls.map(\.method) == [
            "get_xml_childnode_value",
            "add_set_xmlnode",
            "set_single_by_xmlnode"
        ])
        let addCall = rpc.calls[1]
        #expect(addCall.data["url"].text == "X_FH_MobileNetwork.LockCellList.LockCell.")
        #expect(addCall.data["setNode"]["value"]["act"].text == "2")
        #expect(addCall.data["setNode"]["value"]["arfcn"].text == "634464")
        #expect(addCall.data["setNode"]["value"]["pci"].text == "101")
        let enableCall = rpc.calls[2]
        #expect(enableCall.data["url"].text == "X_FH_MobileNetwork.LockCellList.LockEnable")
        #expect(enableCall.data["value"].text == "1")
    }
}

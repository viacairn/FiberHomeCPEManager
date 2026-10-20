import Foundation

/// Settings the firmware actually exposes, read from the node names published in its own
/// `get_xmlnode_js_file` catalog and verified against a live LG6851F (RP0112).
///
/// Every field is optional-safe: a firmware revision that lacks a node yields `nil` rather
/// than a fabricated default, and the UI shows "—" for it.
public struct WiFiNetwork: Identifiable, Sendable, Equatable {
    public var id: Int
    public var ssid: String
    public var enabled: Bool
    /// `2.4G` / `5G`, derived from the radio the SSID is bound to.
    public var band: String
    /// `WPA2-Personal` etc.; empty when the access point does not expose it.
    public var security: String

    public init(id: Int, ssid: String, enabled: Bool, band: String, security: String = "") {
        self.id = id; self.ssid = ssid; self.enabled = enabled
        self.band = band; self.security = security
    }
}

/// The uplink modes offered by the stock WebUI (`/network/networkConn`, `uplinkSelectArr`,
/// captured 2026-10-18). `webValue` is the stock page's internal option value.
///
/// Only the three fixed modes are writable here (via `X_FH_CurrentWANDevice` and
/// `X_FH_Multiwan_Aggregation.Enable`, verified by read-back). The two failover modes are
/// listed so the UI matches the device, but stay disabled until the stock page's submit
/// payload (`wanSelectSubmit`) has been confirmed — see docs/protocol/WEB-API.md.
public enum UplinkTarget: String, Sendable, CaseIterable, Codable {
    case cellular, ethernet, cellularPreferred, ethernetPreferred, aggregation

    public var title: String {
        switch self {
        case .cellular: "蜂窝上行"
        case .ethernet: "以太网上行"
        case .cellularPreferred: "蜂窝优先"
        case .ethernetPreferred: "以太网优先"
        case .aggregation: "双网聚合"
        }
    }

    public var symbol: String {
        switch self {
        case .cellular: "antenna.radiowaves.left.and.right"
        case .ethernet: "cable.connector"
        case .cellularPreferred, .ethernetPreferred: "arrow.triangle.2.circlepath"
        case .aggregation: "bolt.horizontal"
        }
    }

    /// The stock WebUI's option value for this mode.
    public var webValue: String {
        switch self {
        case .cellular: "dev.5G.1_1"
        case .ethernet: "dev.eth.1_2"
        case .cellularPreferred: "nb5g,lan1"
        case .ethernetPreferred: "lan1,nb5g"
        case .aggregation: "aggregation"
        }
    }

    public var isSupported: Bool {
        switch self {
        case .cellular, .ethernet, .aggregation: true
        case .cellularPreferred, .ethernetPreferred: false
        }
    }

    public static let cellularDevice = "InternetGatewayDevice.WANDevice.1."
    public static let ethernetDevice = "InternetGatewayDevice.WANDevice.2."
    public static let deviceNode = "DeviceInfo.X_FH_CurrentWANDevice"
    public static let aggregationNode = "DeviceInfo.X_FH_Multiwan_Aggregation.Enable"

    /// Node writes that put the device into this mode, in order.
    public func writes() -> [(path: String, value: String)] {
        switch self {
        case .cellular:
            [(Self.deviceNode, Self.cellularDevice), (Self.aggregationNode, "0")]
        case .ethernet:
            [(Self.deviceNode, Self.ethernetDevice), (Self.aggregationNode, "0")]
        case .aggregation:
            [(Self.aggregationNode, "1")]
        case .cellularPreferred, .ethernetPreferred:
            []
        }
    }

    /// True when the read-back matches what this mode asked for.
    public func isSatisfied(device: String, aggregation: Bool) -> Bool {
        switch self {
        case .cellular: device == Self.cellularDevice && !aggregation
        case .ethernet: device == Self.ethernetDevice && !aggregation
        case .aggregation: aggregation
        case .cellularPreferred, .ethernetPreferred: false
        }
    }
}

public struct DeviceSettings: Sendable, Equatable {
    public var wifi: [WiFiNetwork] = []
    public var rebootEnabled: Bool = false
    public var rebootTime: String = ""
    public var rebootWeekday: String = ""
    /// `DeviceInfo.X_FH_LedControl.Switch`: the LED master switch.
    public var ledOn: Bool = true
    /// `DeviceInfo.LedSleepControl.Switch`: a night window some firmwares expose. Read-only
    /// here — this unit rejects writes to it.
    public var ledNightMode: Bool = false
    public var ledStart: String = ""
    public var ledEnd: String = ""
    public var fanMode: String = ""
    /// `fanMode` decoded with the stock page's enumeration; nil for an unknown raw value.
    public var fan: FanMode? { FanMode(rawValue: fanMode) }
    /// `WiFi.X_FH_MultiLinkGroupNumberOfEntries`; 0 means this firmware has no MLO groups.
    public var mloGroups: Int = 0
    /// `DeviceInfo.X_FH_CurrentWANDevice`: which WAN device is carrying traffic.
    public var currentWANDevice: String = ""
    /// `DeviceInfo.X_FH_Multiwan_Aggregation.Enable`.
    public var aggregationEnabled: Bool = false

    public init() {}

    /// The mode the device is in right now, derived from what it reports.
    public var activeUplink: UplinkTarget {
        if aggregationEnabled { return .aggregation }
        return currentWANDevice == UplinkTarget.ethernetDevice ? .ethernet : .cellular
    }

    public var activeWiFi: [WiFiNetwork] { wifi.filter(\.enabled) }
    public var supportsMLO: Bool { mloGroups > 0 }
}

/// Reads and writes the small set of settings the firmware contract supports.
///
/// Reads are batched, but only over nodes already observed to exist: the firmware drops an
/// *entire* `get_value_by_xmlnode` batch when it contains one unknown node, which is why
/// earlier probes came back empty.
public struct SettingsService: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    // MARK: Read

    public func read() async throws -> DeviceSettings {
        var settings = DeviceSettings()

        // Batch 1: Radio bands and all 8 SSID slots in a single verified RPC call.
        var wifiBatch: [String: String] = [
            "r1band": "WiFi.Radio.1.OperatingFrequencyBand",
            "r2band": "WiFi.Radio.2.OperatingFrequencyBand",
            "r1en": "WiFi.Radio.1.Enable",
            "r2en": "WiFi.Radio.2.Enable"
        ]
        for index in 1...8 {
            wifiBatch["ssid\(index)_name"] = "WiFi.SSID.\(index).SSID"
            wifiBatch["ssid\(index)_en"] = "WiFi.SSID.\(index).Enable"
            wifiBatch["ssid\(index)_low"] = "WiFi.SSID.\(index).LowerLayers"
        }
        let wifiReply = try await readBatch(wifiBatch)
        let band1 = wifiReply["r1band"].text ?? "2.4G"
        let band2 = wifiReply["r2band"].text ?? "5G"

        for index in 1...8 {
            guard let name = wifiReply["ssid\(index)_name"].text, !name.isEmpty else { continue }
            let lower = wifiReply["ssid\(index)_low"].text ?? ""
            let band = lower.contains("Radio.2") ? band2 : band1
            settings.wifi.append(WiFiNetwork(
                id: index,
                ssid: name,
                enabled: wifiReply["ssid\(index)_en"].text == "1",
                band: band
            ))
        }

        // Batch 2: Security per populated access point (the firmware maps AP n → SSID n).
        if !settings.wifi.isEmpty {
            var secBatch: [String: String] = [:]
            for index in settings.wifi.map(\.id) {
                secBatch["sec\(index)"] = "WiFi.AccessPoint.\(index).Security.ModeEnabled"
            }
            let secReply = try await readBatch(secBatch)
            for position in settings.wifi.indices {
                let id = settings.wifi[position].id
                if let security = secReply["sec\(id)"].text, !security.isEmpty {
                    settings.wifi[position].security = security
                }
            }
        }

        // Batch 3: Reboot schedule, LED controls, fan mode, MLO count, and uplink selection.
        let misc = try await readBatch([
            "reboot_en": "DeviceInfo.TimedReboot.1.enable",
            "reboot_time": "DeviceInfo.TimedReboot.1.time",
            "reboot_days": "DeviceInfo.TimedReboot.1.week_of_day",
            "led_on": "DeviceInfo.X_FH_LedControl.Switch",
            "led_night": "DeviceInfo.LedSleepControl.Switch",
            "led_start": "DeviceInfo.LedSleepControl.StartTime",
            "led_end": "DeviceInfo.LedSleepControl.EndTime",
            "fan_mode": "X_FH_MobileNetwork.FanAutoConfig.mode",
            "mlo_n": "WiFi.X_FH_MultiLinkGroupNumberOfEntries",
            "wan_device": UplinkTarget.deviceNode,
            "wan_agg": UplinkTarget.aggregationNode
        ])
        settings.rebootEnabled = misc["reboot_en"].text == "1"
        settings.rebootTime = misc["reboot_time"].text ?? ""
        settings.rebootWeekday = misc["reboot_days"].text ?? ""
        settings.ledOn = misc["led_on"].text != "0"
        settings.ledNightMode = misc["led_night"].text == "1"
        settings.ledStart = misc["led_start"].text ?? ""
        settings.ledEnd = misc["led_end"].text ?? ""
        settings.fanMode = misc["fan_mode"].text ?? ""
        settings.mloGroups = misc["mlo_n"].text.flatMap(Int.init) ?? 0
        settings.currentWANDevice = misc["wan_device"].text ?? ""
        settings.aggregationEnabled = misc["wan_agg"].text == "1"

        return settings
    }

    /// A one-alias-per-call reader. The firmware drops a whole batch on one unknown node, so
    /// grouping several here is only safe because every path is already verified.
    private func readBatch(_ fields: [String: String]) async throws -> JSONValue {
        try await rpc.call("get_value_by_xmlnode", data: .strings(fields), publicAccess: false)
    }

    // MARK: Write

    /// Writes one node with `set_single_by_xmlnode`.
    ///
    /// The device's own settings pages use exactly this call — captured from the web UI's
    /// LED page: `$post("set_single_by_xmlnode", { url: "…", value: "0" })` returning
    /// `{"success":"true"}`. The multi-node `set_value_by_xmlnode` variant answers
    /// `ERRORSTATUS: 400` for the same node, so single writes are the supported path.
    private func write(_ path: String, _ value: String) async throws -> Bool {
        let reply = try await rpc.call("set_single_by_xmlnode",
                                       data: .object(["url": .string(path), "value": .string(value)]),
                                       publicAccess: false)
        if let success = reply["success"].text { return success == "true" }
        let result = reply["result"].text ?? ""
        return result == "0" || result.isEmpty
    }

    private func writeAll(_ pairs: [(String, String)]) async throws -> Bool {
        for (path, value) in pairs {
            guard try await write(path, value) else { return false }
        }
        return true
    }

    /// Enables or disables one SSID. Changes can drop associated clients, so callers must
    /// confirm with the user first.
    public func setSSIDEnabled(index: Int, enabled: Bool) async throws -> Bool {
        try await write("WiFi.SSID.\(index).Enable", enabled ? "1" : "0")
    }

    /// Renames one SSID.
    public func renameSSID(index: Int, ssid: String) async throws -> Bool {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CPEError.rejected }
        return try await write("WiFi.SSID.\(index).SSID", trimmed)
    }

    /// Timed reboot: `time` is `HH:mm`, `week_of_day` is `Sunday`..`Saturday` or `Everyday`.
    public func setTimedReboot(enabled: Bool, time: String, weekday: String) async throws -> Bool {
        try await writeAll([
            ("DeviceInfo.TimedReboot.1.enable", enabled ? "1" : "0"),
            ("DeviceInfo.TimedReboot.1.time", time),
            ("DeviceInfo.TimedReboot.1.week_of_day", weekday)
        ])
    }

    /// Switches the uplink mode and verifies it by reading the device back.
    ///
    /// Switching can briefly drop the LAN/Wi-Fi path this app is connected through, so the
    /// caller must be prepared for the call to throw even when the write landed.
    public func setUplink(_ target: UplinkTarget) async throws -> Bool {
        guard target.isSupported else { return false }
        for step in target.writes() {
            guard try await write(step.path, step.value) else { return false }
        }
        let reply = try await readBatch([
            "device": UplinkTarget.deviceNode,
            "aggregation": UplinkTarget.aggregationNode
        ])
        return target.isSatisfied(device: reply["device"].text ?? "",
                                  aggregation: reply["aggregation"].text == "1")
    }

    /// The LED master switch.
    public func setLEDEnabled(_ enabled: Bool) async throws -> Bool {
        try await write("DeviceInfo.X_FH_LedControl.Switch", enabled ? "1" : "0")
    }

    public static let fanNode = "X_FH_MobileNetwork.FanAutoConfig.mode"

    /// Sets `FanAutoConfig.mode` and confirms it by reading the node back.
    public func setFanMode(_ mode: FanMode) async throws -> Bool {
        let acknowledgement = try await rpc.call("set_value_by_xmlnode", data: .object([
            "url": .strings(["mode": Self.fanNode]),
            "value": .strings(["mode": mode.rawValue])
        ]), publicAccess: false)
        try FirmwareNodes(rpc: rpc).ensureWrite(acknowledgement)
        let reply = try await readBatch(["mode": Self.fanNode])
        guard reply["mode"].text == mode.rawValue else { throw CPEError.uncertain }
        return true
    }
}

import Foundation

/// `X_FH_MobileNetwork.NetworkSettings.AntennaOutterSwitch_Type`.
public enum AntennaType: String, Sendable, CaseIterable, Codable {
    case automatic = "0"
    case n41 = "1"
    case n78n77 = "2"

    public var title: String {
        switch self {
        case .automatic: "自动"
        case .n41: "N41"
        case .n78n77: "N78/N77"
        }
    }
}

public struct MobileNetworkState: Sendable, Equatable {
    public var airplaneMode: Bool
    public var cellularDataEnabled: Bool
    public var antennaEnabled: Bool
    public var antennaType: AntennaType?
    public var carrierRestricted: Bool
    public var cellularBlocked: Bool { airplaneMode || carrierRestricted }
    /// The WAN service the cellular-data switch belongs to.
    public var cellularWAN: WANConnectionRef?

    public init(airplaneMode: Bool, cellularDataEnabled: Bool,
                antennaEnabled: Bool, antennaType: AntennaType? = nil,
                cellularWAN: WANConnectionRef? = nil, carrierRestricted: Bool = false) {
        self.airplaneMode = airplaneMode
        self.cellularDataEnabled = cellularDataEnabled
        self.antennaEnabled = antennaEnabled
        self.antennaType = antennaType
        self.cellularWAN = cellularWAN
        self.carrierRestricted = carrierRestricted
    }
}

/// Airplane mode, cellular data and the external-antenna switch.
///
/// Contracts taken from the stock `networkSet` and `antennaSet` pages:
/// - `airplan_on` and the WAN `Enable` node use `set_single_by_xmlnode`;
/// - the antenna switch and type are written together with `set_value_by_xmlnode`.
///
/// Airplane mode can briefly take the radio down, so every write is followed by a bounded
/// read-back; a timeout is reported as `uncertain`, never as success.
public struct MobileNetworkService: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    public static let airplaneNode = "X_FH_MobileNetwork.NetworkSettings.airplan_on"
    public static let antennaSwitchNode = "X_FH_MobileNetwork.NetworkSettings.AntennaOutterSwitch"
    public static let antennaTypeNode = "X_FH_MobileNetwork.NetworkSettings.AntennaOutterSwitch_Type"
    private static let carrierLockNode = "X_FH_MobileNetwork.NetworkSettings.CarrierLockEnable"

    public func read() async throws -> MobileNetworkState {
        let nodes = FirmwareNodes(rpc: rpc)
        let values = try await nodes.read([
            "airplane": Self.airplaneNode,
            "antenna": Self.antennaSwitchNode,
            "antennaType": Self.antennaTypeNode,
            "carrier": Self.carrierLockNode
        ])
        let airplaneMode = try FirmwareNodes.flag(values["airplane"])
        let antennaEnabled = try FirmwareNodes.flag(values["antenna"])
        let antennaType = values["antennaType"].text.flatMap(AntennaType.init(rawValue:))
        guard !antennaEnabled || antennaType != nil else { throw CPEError.malformedResponse }
        let restricted = try await carrierRestriction(values["carrier"])
        guard let wan = try await WANDiscovery.cellular(rpc) else {
            throw CPEError.unsupported("未找到蜂窝 WAN 连接。")
        }
        let reply = try await nodes.read(["enable": wan.root + "Enable"])
        let dataEnabled = try FirmwareNodes.flag(reply["enable"])
        return MobileNetworkState(
            airplaneMode: airplaneMode,
            cellularDataEnabled: dataEnabled,
            antennaEnabled: antennaEnabled,
            antennaType: antennaType,
            cellularWAN: wan,
            carrierRestricted: restricted
        )
    }

    public func setAirplaneMode(_ enabled: Bool) async throws -> MobileNetworkState {
        try await FirmwareNodes(rpc: rpc).setSingle(Self.airplaneNode, enabled ? "1" : "0")
        return try await settle { $0.airplaneMode == enabled }
    }

    public func setCellularData(_ enabled: Bool) async throws -> MobileNetworkState {
        let nodes = FirmwareNodes(rpc: rpc)
        let limits = try await nodes.read(["airplane": Self.airplaneNode, "carrier": Self.carrierLockNode])
        let airplane = try FirmwareNodes.flag(limits["airplane"])
        guard !airplane else {
            throw CPEError.unsupported("请先关闭飞行模式，再更改蜂窝数据。")
        }
        let restricted = try await carrierRestriction(limits["carrier"])
        guard !restricted else {
            throw CPEError.unsupported("当前 SIM 卡不符合运营商限制，无法更改蜂窝数据。")
        }
        guard let wan = try await WANDiscovery.cellular(rpc) else {
            throw CPEError.unsupported("未找到蜂窝 WAN 连接。")
        }
        try await nodes.setSingle(wan.root + "Enable", enabled ? "1" : "0")
        return try await settle { $0.cellularWAN?.id == wan.id && $0.cellularDataEnabled == enabled }
    }

    /// Subscriber fields are read only when the explicit carrier-lock switch is on.
    /// They stay local to this check; the returned state retains only the result.
    private func carrierRestriction(_ flag: JSONValue) async throws -> Bool {
        guard try FirmwareNodes.flag(flag) else { return false }
        let values = try await FirmwareNodes(rpc: rpc).read([
            "serials": "X_FH_MobileNetwork.NetworkSettings.CarrierSerialNum",
            "imsi": "X_FH_MobileNetwork.SIM.1.IMSI"
        ])
        guard case .string(let serials) = values["serials"], case .string(let imsi) = values["imsi"] else {
            throw CPEError.malformedResponse
        }
        return !serials.split(separator: ",").contains { !$0.isEmpty && imsi.hasPrefix($0) }
    }

    public func setAntenna(enabled: Bool, type: AntennaType) async throws -> MobileNetworkState {
        var pairs = [(path: Self.antennaSwitchNode, value: enabled ? "1" : "0")]
        if enabled { pairs.append((path: Self.antennaTypeNode, value: type.rawValue)) }
        try await FirmwareNodes(rpc: rpc).setMulti(pairs)
        return try await settle {
            $0.antennaEnabled == enabled && (!enabled || $0.antennaType == type)
        }
    }

    /// The firmware applies these switches asynchronously; poll instead of assuming the
    /// first read reflects the write.
    private func settle(_ matches: (MobileNetworkState) -> Bool) async throws -> MobileNetworkState {
        for attempt in 0..<5 {
            try await Task.sleep(for: .milliseconds(attempt == 0 ? 600 : 1_200))
            let state = try await read()
            if matches(state) { return state }
        }
        throw CPEError.uncertain
    }
}

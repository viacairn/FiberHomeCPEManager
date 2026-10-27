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
    public var cellularBlocked: Bool { airplaneMode }
    /// The WAN service the cellular-data switch belongs to.
    public var cellularWAN: WANConnectionRef?

    public init(airplaneMode: Bool, cellularDataEnabled: Bool,
                antennaEnabled: Bool, antennaType: AntennaType? = nil,
                cellularWAN: WANConnectionRef? = nil) {
        self.airplaneMode = airplaneMode
        self.cellularDataEnabled = cellularDataEnabled
        self.antennaEnabled = antennaEnabled
        self.antennaType = antennaType
        self.cellularWAN = cellularWAN
    }
}

/// Airplane mode, cellular data and the external-antenna switch.
///
/// Contracts taken from the stock `networkSet` and `antennaSet` pages:
/// - `airplan_on` and the WAN `Enable` node use `set_single_by_xmlnode`;
/// - the antenna switch and type are written together with `set_value_by_xmlnode`.
///
/// Successful receipts are followed by one normal state refresh. Acknowledged fields
/// retain their requested values until ordinary polling catches up with the firmware.
public struct MobileNetworkService: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    public static let airplaneNode = "X_FH_MobileNetwork.NetworkSettings.airplan_on"
    public static let antennaSwitchNode = "X_FH_MobileNetwork.NetworkSettings.AntennaOutterSwitch"
    public static let antennaTypeNode = "X_FH_MobileNetwork.NetworkSettings.AntennaOutterSwitch_Type"

    public func read() async throws -> MobileNetworkState {
        let nodes = FirmwareNodes(rpc: rpc)
        let values = try await nodes.read([
            "airplane": Self.airplaneNode,
            "antenna": Self.antennaSwitchNode,
            "antennaType": Self.antennaTypeNode
        ])
        let airplaneMode = try FirmwareNodes.flag(values["airplane"])
        let antennaEnabled = try FirmwareNodes.flag(values["antenna"])
        let antennaType = values["antennaType"].text.flatMap(AntennaType.init(rawValue:))
        guard !antennaEnabled || antennaType != nil else { throw CPEError.malformedResponse }
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
            cellularWAN: wan
        )
    }

    public func setAirplaneMode(_ enabled: Bool) async throws -> MobileNetworkState {
        try await FirmwareNodes(rpc: rpc).setSingle(Self.airplaneNode, FirmwareNodes.bool(enabled))
        try await Task.sleep(for: .milliseconds(600))
        var state = try await read()
        state.airplaneMode = enabled
        return state
    }

    public func setCellularData(_ enabled: Bool) async throws -> MobileNetworkState {
        let nodes = FirmwareNodes(rpc: rpc)
        let limits = try await nodes.read(["airplane": Self.airplaneNode])
        let airplane = try FirmwareNodes.flag(limits["airplane"])
        guard !airplane else {
            throw CPEError.unsupported("请先关闭飞行模式，再更改蜂窝数据。")
        }
        guard let wan = try await WANDiscovery.cellular(rpc) else {
            throw CPEError.unsupported("未找到蜂窝 WAN 连接。")
        }
        try await nodes.setSingle(wan.root + "Enable", FirmwareNodes.bool(enabled))
        var state = try await read()
        state.cellularDataEnabled = enabled
        return state
    }

    public func setAntenna(enabled: Bool, type: AntennaType) async throws -> MobileNetworkState {
        var pairs = [(path: Self.antennaSwitchNode, value: FirmwareNodes.bool(enabled))]
        if enabled { pairs.append((path: Self.antennaTypeNode, value: type.rawValue)) }
        try await FirmwareNodes(rpc: rpc).setMulti(pairs)
        var state = try await read()
        state.antennaEnabled = enabled
        if enabled { state.antennaType = type }
        return state
    }

}

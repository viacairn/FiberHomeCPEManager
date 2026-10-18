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
    /// The WAN service the cellular-data switch belongs to.
    public var cellularWAN: WANConnectionRef?

    public init(airplaneMode: Bool = false, cellularDataEnabled: Bool = false,
                antennaEnabled: Bool = false, antennaType: AntennaType? = nil,
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
/// Airplane mode can briefly take the radio down, so every write is followed by a bounded
/// read-back; a timeout is reported as `uncertain`, never as success.
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
        let wan = await WANDiscovery.cellular(rpc)
        var dataEnabled = false
        if let wan {
            let reply = try await nodes.read(["enable": wan.root + "Enable"])
            dataEnabled = reply["enable"].text == "1"
        }
        return MobileNetworkState(
            airplaneMode: values["airplane"].text == "1",
            cellularDataEnabled: dataEnabled,
            antennaEnabled: values["antenna"].text == "1",
            antennaType: values["antennaType"].text.flatMap(AntennaType.init(rawValue:)),
            cellularWAN: wan
        )
    }

    public func setAirplaneMode(_ enabled: Bool) async throws -> MobileNetworkState {
        try await FirmwareNodes(rpc: rpc).setSingle(Self.airplaneNode, enabled ? "1" : "0")
        return try await settle { $0.airplaneMode == enabled }
    }

    public func setCellularData(_ enabled: Bool) async throws -> MobileNetworkState {
        guard let wan = await WANDiscovery.cellular(rpc) else {
            throw CPEError.unsupported("未找到蜂窝 WAN 连接。")
        }
        try await FirmwareNodes(rpc: rpc).setSingle(wan.root + "Enable", enabled ? "1" : "0")
        return try await settle { $0.cellularDataEnabled == enabled }
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
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 600 : 1_200))
            let state = try await read()
            if matches(state) { return state }
        }
        throw CPEError.uncertain
    }
}

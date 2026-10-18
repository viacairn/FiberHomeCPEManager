import Foundation

public enum PortMappingProtocol: String, Sendable, CaseIterable, Codable {
    case both = "BOTH"
    case tcp = "TCP"
    case udp = "UDP"

    public var title: String {
        switch self {
        case .both: "TCP+UDP"
        case .tcp: "TCP"
        case .udp: "UDP"
        }
    }
}

public struct PortMappingEntry: Sendable, Equatable, Identifiable {
    public var wan: WANConnectionRef
    public var index: Int
    public var localIP: String
    public var internalPort: Int
    public var internalEnd: Int
    public var externalPort: Int
    public var externalEnd: Int
    public var proto: PortMappingProtocol
    public var enabled: Bool

    public var id: String { "\(wan.id)-\(index)" }
    public var internalRange: String { internalPort == internalEnd ? "\(internalPort)" : "\(internalPort)-\(internalEnd)" }
    public var externalRange: String { externalPort == externalEnd ? "\(externalPort)" : "\(externalPort)-\(externalEnd)" }
    public var isRange: Bool { internalPort != internalEnd || externalPort != externalEnd }

    public init(wan: WANConnectionRef, index: Int, localIP: String,
                internalPort: Int, internalEnd: Int, externalPort: Int, externalEnd: Int,
                proto: PortMappingProtocol, enabled: Bool) {
        self.wan = wan; self.index = index; self.localIP = localIP
        self.internalPort = internalPort; self.internalEnd = internalEnd
        self.externalPort = externalPort; self.externalEnd = externalEnd
        self.proto = proto; self.enabled = enabled
    }
}

public struct PortMappingInput: Sendable, Equatable {
    public var wan: WANConnectionRef
    public var localIP: String
    public var internalPort: Int
    public var internalEnd: Int
    public var externalPort: Int
    public var externalEnd: Int
    public var proto: PortMappingProtocol
    public var enabled: Bool

    public init(wan: WANConnectionRef, localIP: String, internalPort: Int, internalEnd: Int,
                externalPort: Int, externalEnd: Int, proto: PortMappingProtocol, enabled: Bool) {
        self.wan = wan
        self.localIP = localIP.trimmingCharacters(in: .whitespacesAndNewlines)
        self.internalPort = internalPort; self.internalEnd = internalEnd
        self.externalPort = externalPort; self.externalEnd = externalEnd
        self.proto = proto; self.enabled = enabled
    }

    public var validationError: String? {
        guard Self.isIPv4(localIP) else { return "请输入有效的内网 IPv4 地址。" }
        guard (1...65535).contains(internalPort), (1...65535).contains(internalEnd),
              (1...65535).contains(externalPort), (1...65535).contains(externalEnd) else {
            return "端口必须在 1–65535 之间。"
        }
        guard internalPort <= internalEnd else { return "内部端口起始值不能大于结束值。" }
        guard externalPort <= externalEnd else { return "外部端口起始值不能大于结束值。" }
        return nil
    }

    static func isIPv4(_ text: String) -> Bool {
        guard let value = DHCPReservation.ipv4Value(text) else { return false }
        return value >> 24 != 0 && value >> 24 != 127 && value >> 24 < 224
    }
}

/// The stock `portForward` page addresses each WAN's mapping table as
/// `…WANIPConnection.1.PortMapping` and creates entries with `add_xmlnode`.
public struct PortMappingService: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    public static let maxEntriesPerWAN = 8

    public func read() async throws -> [PortMappingEntry] {
        let wans = try await WANDiscovery.connections(rpc)
        guard !wans.isEmpty else { throw CPEError.unsupported("未找到可用的 WAN 连接。") }
        var entries: [PortMappingEntry] = []
        for wan in wans {
            entries += try await readEntries(on: wan)
        }
        return entries.sorted { $0.wan.id == $1.wan.id ? $0.index < $1.index : $0.wan.id < $1.wan.id }
    }

    private func readEntries(on wan: WANConnectionRef) async throws -> [PortMappingEntry] {
        let rows = try await FirmwareNodes(rpc: rpc).child(root: wan.portMappingRoot + ".", fields: [
                "enabled": "PortMappingEnabled",
                "localIP": "InternalClient",
                "internalPort": "InternalPort",
                "internalEnd": "X_FH_InternalPortEndRange",
                "protocol": "PortMappingProtocol",
                "externalPort": "ExternalPort",
                "externalEnd": "ExternalPortEndRange"
            ])
        var entries: [PortMappingEntry] = []
        var indices = Set<Int>()
        for row in rows {
            guard let index = row["child_node_idx"].nodeIndex, indices.insert(index).inserted,
                  let localIP = row["localIP"].text,
                  let internalPort = row["internalPort"].text.flatMap(Int.init),
                  let internalEnd = row["internalEnd"].text.flatMap(Int.init),
                  let externalPort = row["externalPort"].text.flatMap(Int.init),
                  let externalEnd = row["externalEnd"].text.flatMap(Int.init),
                  let protocolText = row["protocol"].text,
                  let proto = PortMappingProtocol(rawValue: protocolText) else {
                throw CPEError.malformedResponse
            }
            let enabled = try FirmwareNodes.flag(row["enabled"])
            let parsed = PortMappingInput(wan: wan, localIP: localIP, internalPort: internalPort,
                                          internalEnd: internalEnd, externalPort: externalPort,
                                          externalEnd: externalEnd, proto: proto, enabled: enabled)
            guard parsed.validationError == nil else { throw CPEError.malformedResponse }
            entries.append(PortMappingEntry(wan: wan, index: index, localIP: localIP,
                                             internalPort: internalPort, internalEnd: internalEnd,
                                             externalPort: externalPort, externalEnd: externalEnd,
                                             proto: proto, enabled: enabled))
        }
        return entries
    }

    private func readBack(on wan: WANConnectionRef) async throws -> [PortMappingEntry] {
        let wans = try await WANDiscovery.connections(rpc)
        guard let current = wans.first(where: { $0.id == wan.id }) else { throw CPEError.uncertain }
        return try await readEntries(on: current)
    }

    @discardableResult
    public func add(_ input: PortMappingInput) async throws -> PortMappingEntry {
        if let error = input.validationError { throw CPEError.unsupported(error) }
        try await validateLANAddress(input.localIP)
        let nodes = FirmwareNodes(rpc: rpc)
        let services = try await WANDiscovery.services(rpc)
        guard services.contains(where: { $0.id == input.wan.id }) else { throw CPEError.uncertain }
        var existing: [PortMappingEntry] = []
        for service in services where service.device == input.wan.device {
            existing += try await readEntries(on: service)
        }
        guard existing.filter({ $0.wan.id == input.wan.id }).count < Self.maxEntriesPerWAN else {
            throw CPEError.unsupported("每个 WAN 最多可添加 \(Self.maxEntriesPerWAN) 条端口映射。")
        }
        // The stock page rejects overlap across all services on the selected WAN device,
        // including disabled mappings and mappings using a different protocol.
        guard !existing.contains(where: { max($0.externalPort, input.externalPort) <= min($0.externalEnd, input.externalEnd) }) else {
            throw CPEError.unsupported("外部端口范围与此 WAN 上的现有映射重叠。")
        }
        let index = try await nodes.add(root: input.wan.portMappingRoot, key: "portMap")
        let base = "\(input.wan.portMappingRoot).\(index)."
        try await nodes.setMulti([
            (base + "PortMappingEnabled", input.enabled ? "1" : "0"),
            (base + "InternalClient", input.localIP),
            (base + "InternalPort", String(input.internalPort)),
            (base + "X_FH_InternalPortEndRange", String(input.internalEnd)),
            (base + "PortMappingProtocol", input.proto.rawValue),
            (base + "ExternalPort", String(input.externalPort)),
            (base + "ExternalPortEndRange", String(input.externalEnd))
        ])
        return try await verify(input, index: index)
    }

    private func validateLANAddress(_ ip: String) async throws {
        let root = "LANDevice.1.LANHostConfigManagement.IPInterface.1."
        let values = try await FirmwareNodes(rpc: rpc).read([
            "router": root + "IPInterfaceIPAddress", "mask": root + "IPInterfaceSubnetMask"
        ])
        guard let router = values["router"].text.flatMap(DHCPReservation.ipv4Value),
              let mask = values["mask"].text.flatMap(DHCPReservation.ipv4Value),
              let address = DHCPReservation.ipv4Value(ip) else { throw CPEError.malformedResponse }
        let hostMask = ~mask
        guard mask != 0, hostMask > 1, hostMask & (hostMask &+ 1) == 0 else { throw CPEError.malformedResponse }
        let network = router & mask
        let broadcast = network | hostMask
        guard router != network, router != broadcast else { throw CPEError.malformedResponse }
        guard address & mask == network, address != network, address != broadcast, address != router else {
            throw CPEError.unsupported("映射目标必须是当前 LAN 子网内的主机地址，且不能使用路由器地址。")
        }
    }

    public func delete(_ entry: PortMappingEntry) async throws {
        try await FirmwareNodes(rpc: rpc).delete(root: entry.wan.portMappingRoot, index: entry.index)
        let remaining = try await readBack(on: entry.wan)
        guard !remaining.contains(where: { $0.index == entry.index }) else {
            throw CPEError.uncertain
        }
    }

    @discardableResult
    public func setEnabled(_ entry: PortMappingEntry, _ enabled: Bool) async throws -> PortMappingEntry {
        guard entry.index > 0 else { throw CPEError.malformedResponse }
        let path = "\(entry.wan.portMappingRoot).\(entry.index).PortMappingEnabled"
        try await FirmwareNodes(rpc: rpc).setMulti([(path, enabled ? "1" : "0")])
        let updated = try await readBack(on: entry.wan)
        guard let saved = updated.first(where: { $0.index == entry.index }),
              saved.enabled == enabled else { throw CPEError.uncertain }
        return saved
    }

    private func verify(_ input: PortMappingInput, index: Int) async throws -> PortMappingEntry {
        let entries = try await readBack(on: input.wan)
        guard let saved = entries.first(where: { $0.index == index }),
              saved.localIP == input.localIP, saved.internalPort == input.internalPort,
              saved.internalEnd == input.internalEnd, saved.externalPort == input.externalPort,
              saved.externalEnd == input.externalEnd, saved.proto == input.proto,
              saved.enabled == input.enabled else { throw CPEError.uncertain }
        return saved
    }
}

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
        var skippedRows = 0
        for wan in wans {
            let table = try await readEntries(on: wan)
            entries += table.entries
            skippedRows += table.rowCount - table.entries.count
        }
        FirmwareNodes.reportSkippedRows(skippedRows, table: "端口映射表")
        return entries.sorted { $0.wan.id == $1.wan.id ? $0.index < $1.index : $0.wan.id < $1.wan.id }
    }

    private func readEntries(on wan: WANConnectionRef) async throws -> (entries: [PortMappingEntry], rowCount: Int) {
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
            guard let index = row["child_node_idx"].nodeIndex,
                  let localIP = row["localIP"].text,
                  let internalPort = row["internalPort"].text.flatMap(Int.init),
                  let internalEnd = row["internalEnd"].text.flatMap(Int.init),
                  let externalPort = row["externalPort"].text.flatMap(Int.init),
                  let externalEnd = row["externalEnd"].text.flatMap(Int.init),
                  let protocolText = row["protocol"].text,
                  let proto = PortMappingProtocol(rawValue: protocolText),
                  let enabled = try? FirmwareNodes.flag(row["enabled"]),
                  indices.insert(index).inserted else { continue }
            entries.append(PortMappingEntry(wan: wan, index: index, localIP: localIP,
                                             internalPort: internalPort, internalEnd: internalEnd,
                                             externalPort: externalPort, externalEnd: externalEnd,
                                             proto: proto, enabled: enabled))
        }
        return (entries, rows.count)
    }

    @discardableResult
    public func add(_ input: PortMappingInput) async throws -> [PortMappingEntry] {
        if let error = input.validationError { throw CPEError.unsupported(error) }
        let existing = try await readEntries(on: input.wan)
        guard existing.rowCount < Self.maxEntriesPerWAN else {
            throw CPEError.unsupported("每个 WAN 最多可添加 \(Self.maxEntriesPerWAN) 条端口映射。")
        }
        let index = try await FirmwareNodes(rpc: rpc).add(root: input.wan.portMappingRoot, key: "portMap")
        try await write(input, index: index)
        return try await read()
    }

    @discardableResult
    public func update(_ entry: PortMappingEntry, with input: PortMappingInput) async throws -> [PortMappingEntry] {
        if let error = input.validationError { throw CPEError.unsupported(error) }
        guard entry.wan.id == input.wan.id else { throw CPEError.unsupported("端口映射所属 WAN 不一致。") }
        guard entry.index > 0 else { throw CPEError.malformedResponse }
        try await write(input, index: entry.index)
        return try await read()
    }

    private func write(_ input: PortMappingInput, index: Int) async throws {
        let base = "\(input.wan.portMappingRoot).\(index)."
        try await FirmwareNodes(rpc: rpc).setMulti([
            (base + "PortMappingEnabled", FirmwareNodes.bool(input.enabled)),
            (base + "InternalClient", input.localIP),
            (base + "InternalPort", String(input.internalPort)),
            (base + "X_FH_InternalPortEndRange", String(input.internalEnd)),
            (base + "PortMappingProtocol", input.proto.rawValue),
            (base + "ExternalPort", String(input.externalPort)),
            (base + "ExternalPortEndRange", String(input.externalEnd))
        ])
    }

    @discardableResult
    public func delete(_ entry: PortMappingEntry) async throws -> [PortMappingEntry] {
        try await FirmwareNodes(rpc: rpc).delete(root: entry.wan.portMappingRoot, index: entry.index)
        return try await read()
    }

    @discardableResult
    public func setEnabled(_ entry: PortMappingEntry, _ enabled: Bool) async throws -> [PortMappingEntry] {
        guard entry.index > 0 else { throw CPEError.malformedResponse }
        let path = "\(entry.wan.portMappingRoot).\(entry.index).PortMappingEnabled"
        try await FirmwareNodes(rpc: rpc).setMulti([(path, FirmwareNodes.bool(enabled))])
        return try await read()
    }
}

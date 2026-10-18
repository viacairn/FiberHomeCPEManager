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
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy {
            guard !$0.isEmpty, $0.count <= 3, $0.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int($0) else { return false }
            return (0...255).contains(value)
        }
    }
}

/// The stock `portForward` page addresses each WAN's mapping table as
/// `…WANIPConnection.1.PortMapping` and creates entries with `add_xmlnode`.
public struct PortMappingService: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    public static let maxEntriesPerWAN = 8

    public func read() async throws -> [PortMappingEntry] {
        let nodes = FirmwareNodes(rpc: rpc)
        let wans = await WANDiscovery.connections(rpc)
        guard !wans.isEmpty else { throw CPEError.unsupported("未找到可用的 WAN 连接。") }
        var entries: [PortMappingEntry] = []
        for wan in wans {
            let rows = try await nodes.child(root: wan.portMappingRoot + ".", fields: [
                "enabled": "PortMappingEnabled",
                "localIP": "InternalClient",
                "internalPort": "InternalPort",
                "internalEnd": "X_FH_InternalPortEndRange",
                "protocol": "PortMappingProtocol",
                "externalPort": "ExternalPort",
                "externalEnd": "ExternalPortEndRange"
            ])
            for (offset, row) in rows.enumerated() {
                let index = row["child_node_idx"].nodeIndex ?? offset + 1
                guard let internalPort = row["internalPort"].text.flatMap(Int.init),
                      let externalPort = row["externalPort"].text.flatMap(Int.init) else {
                    throw CPEError.malformedResponse
                }
                let internalEnd = row["internalEnd"].text.flatMap(Int.init) ?? internalPort
                let externalEnd = row["externalEnd"].text.flatMap(Int.init) ?? externalPort
                entries.append(PortMappingEntry(
                    wan: wan, index: index,
                    localIP: row["localIP"].text ?? "",
                    internalPort: internalPort, internalEnd: internalEnd,
                    externalPort: externalPort, externalEnd: externalEnd,
                    proto: PortMappingProtocol(rawValue: row["protocol"].text ?? "") ?? .both,
                    enabled: row["enabled"].text == "1"
                ))
            }
        }
        return entries.sorted { $0.wan.device == $1.wan.device ? $0.index < $1.index : $0.wan.device < $1.wan.device }
    }

    @discardableResult
    public func add(_ input: PortMappingInput) async throws -> PortMappingEntry {
        if let error = input.validationError { throw CPEError.unsupported(error) }
        let nodes = FirmwareNodes(rpc: rpc)
        let existing = try await read().filter { $0.wan == input.wan }
        guard existing.count < Self.maxEntriesPerWAN else {
            throw CPEError.unsupported("每个 WAN 最多可添加 \(Self.maxEntriesPerWAN) 条端口映射。")
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
        return try await verify(wan: input.wan, index: index, localIP: input.localIP)
    }

    public func delete(_ entry: PortMappingEntry) async throws {
        try await FirmwareNodes(rpc: rpc).delete(root: entry.wan.portMappingRoot, index: entry.index)
        let remaining = try await read()
        guard !remaining.contains(where: { $0.wan == entry.wan && $0.index == entry.index }) else {
            throw CPEError.uncertain
        }
    }

    @discardableResult
    public func setEnabled(_ entry: PortMappingEntry, _ enabled: Bool) async throws -> PortMappingEntry {
        let path = "\(entry.wan.portMappingRoot).\(entry.index).PortMappingEnabled"
        try await FirmwareNodes(rpc: rpc).setMulti([(path, enabled ? "1" : "0")])
        let updated = try await read()
        guard let saved = updated.first(where: { $0.wan == entry.wan && $0.index == entry.index }),
              saved.enabled == enabled else { throw CPEError.uncertain }
        return saved
    }

    private func verify(wan: WANConnectionRef, index: Int, localIP: String) async throws -> PortMappingEntry {
        let entries = try await read()
        guard let saved = entries.first(where: { $0.wan == wan && $0.index == index }),
              saved.localIP == localIP else { throw CPEError.uncertain }
        return saved
    }
}

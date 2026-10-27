import Foundation

public struct DDNSEntry: Sendable, Equatable, Identifiable {
    public var wan: WANConnectionRef
    /// The firmware's `child_node_idx` inside this WAN's DDNS table.
    public var index: Int
    public var provider: String
    public var hostname: String
    public var username: String
    public var password: String
    public var enabled: Bool

    public var id: String { "\(wan.id)-\(index)" }

    public var providerTitle: String {
        switch provider {
        case "dyndns": "DynDNS"
        case "tzo": "TZO"
        case "ORAY": "oray.com"
        case "No-IP.com": "No-IP.com"
        case "": "—"
        default: provider
        }
    }

    public init(wan: WANConnectionRef, index: Int, provider: String, hostname: String,
                username: String, password: String, enabled: Bool) {
        self.wan = wan; self.index = index; self.provider = provider
        self.hostname = hostname; self.username = username; self.password = password
        self.enabled = enabled
    }
}

public struct DDNSInput: Sendable, Equatable {
    public var wan: WANConnectionRef
    public var provider: String
    public var hostname: String
    public var username: String
    public var password: String
    public var enabled: Bool

    public init(wan: WANConnectionRef, provider: String, hostname: String,
                username: String, password: String, enabled: Bool) {
        self.wan = wan
        self.provider = provider
        self.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        self.enabled = enabled
    }

    public static let providers = ["dyndns", "tzo", "ORAY", "No-IP.com"]

    public var validationError: String? {
        if provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请选择或填写 DDNS 服务商。"
        }
        if hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写域名或主机名。" }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写 DDNS 用户名。" }
        if password.isEmpty { return "请填写 DDNS 密码。" }
        if [provider, hostname, username, password].contains(where: { $0.count > 64 }) {
            return "DDNS 服务商地址、域名、用户名和密码均不能超过 64 个字符。"
        }
        return nil
    }
}

/// The stock page stores DDNS entries as a child table below each WAN's
/// `X_FH_DDNSConfiguration`. New entries are created with `add_xmlnode` and then filled
/// with one multi-node write, exactly like the page.
public struct DDNSService: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }
    public static let maxEntriesPerWAN = 4

    public func read() async throws -> [DDNSEntry] {
        let wans = try await WANDiscovery.connections(rpc)
        guard !wans.isEmpty else { throw CPEError.unsupported("未找到可用的 WAN 连接。") }
        var entries: [DDNSEntry] = []
        var skippedRows = 0
        for wan in wans {
            let table = try await readEntries(on: wan)
            entries += table.entries
            skippedRows += table.rowCount - table.entries.count
        }
        FirmwareNodes.reportSkippedRows(skippedRows, table: "DDNS 表")
        return entries.sorted { $0.wan.id == $1.wan.id ? $0.index < $1.index : $0.wan.id < $1.wan.id }
    }

    private func readEntries(on wan: WANConnectionRef) async throws -> (entries: [DDNSEntry], rowCount: Int) {
        let rows = try await FirmwareNodes(rpc: rpc).child(root: wan.ddnsRoot, fields: [
            "enabled": "DDNSCfgEnabled", "provider": "DDNSProvider", "host": "DDNSHostName",
            "user": "DDNSUsername", "password": "DDNSPassword"
        ])
        var entries: [DDNSEntry] = []
        var indices = Set<Int>()
        for row in rows {
            guard let index = row["child_node_idx"].nodeIndex,
                  case .string(let provider) = row["provider"], case .string(let hostname) = row["host"],
                  case .string(let username) = row["user"], case .string(let password) = row["password"],
                  let enabled = try? FirmwareNodes.flag(row["enabled"]),
                  indices.insert(index).inserted else {
                continue
            }
            entries.append(DDNSEntry(
                wan: wan, index: index,
                provider: provider, hostname: hostname, username: username, password: password,
                enabled: enabled
            ))
        }
        return (entries, rows.count)
    }

    @discardableResult
    public func add(_ input: DDNSInput) async throws -> [DDNSEntry] {
        if let error = input.validationError { throw CPEError.unsupported(error) }
        let existing = try await readEntries(on: input.wan)
        guard existing.rowCount < Self.maxEntriesPerWAN else {
            throw CPEError.unsupported("每个 WAN 最多可添加 \(Self.maxEntriesPerWAN) 条 DDNS 配置。")
        }
        let index = try await FirmwareNodes(rpc: rpc).add(root: input.wan.ddnsRoot, key: "ddns")
        try await write(input, index: index)
        return try await read()
    }

    @discardableResult
    public func update(_ entry: DDNSEntry, with input: DDNSInput) async throws -> [DDNSEntry] {
        if let error = input.validationError { throw CPEError.unsupported(error) }
        guard entry.wan.id == input.wan.id else { throw CPEError.unsupported("DDNS 条目所属 WAN 不一致。") }
        guard entry.index > 0 else { throw CPEError.malformedResponse }
        try await write(input, index: entry.index)
        return try await read()
    }

    private func write(_ input: DDNSInput, index: Int) async throws {
        let base = "\(input.wan.ddnsRoot).\(index)."
        try await FirmwareNodes(rpc: rpc).setMulti([
            (base + "DDNSCfgEnabled", FirmwareNodes.bool(input.enabled)),
            (base + "DDNSProvider", input.provider),
            (base + "DDNSHostName", input.hostname),
            (base + "DDNSUsername", input.username),
            (base + "DDNSPassword", input.password)
        ])
    }

    @discardableResult
    public func delete(_ entry: DDNSEntry) async throws -> [DDNSEntry] {
        try await FirmwareNodes(rpc: rpc).delete(root: entry.wan.ddnsRoot, index: entry.index)
        return try await read()
    }

    @discardableResult
    public func setEnabled(_ entry: DDNSEntry, _ enabled: Bool) async throws -> [DDNSEntry] {
        guard entry.index > 0 else { throw CPEError.malformedResponse }
        let base = "\(entry.wan.ddnsRoot).\(entry.index)."
        try await FirmwareNodes(rpc: rpc).setSingle(base + "DDNSCfgEnabled", FirmwareNodes.bool(enabled))
        return try await read()
    }
}

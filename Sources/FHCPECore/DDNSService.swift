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
        if hostname.isEmpty { return "请填写域名或主机名。" }
        if username.isEmpty { return "请填写 DDNS 用户名。" }
        if password.isEmpty { return "请填写 DDNS 密码。" }
        return nil
    }
}

/// The stock page stores DDNS entries as a child table below each WAN's
/// `X_FH_DDNSConfiguration`. New entries are created with `add_xmlnode` and then filled
/// with one multi-node write, exactly like the page.
public struct DDNSService: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    public func read() async throws -> [DDNSEntry] {
        let nodes = FirmwareNodes(rpc: rpc)
        let wans = await WANDiscovery.connections(rpc)
        guard !wans.isEmpty else { throw CPEError.unsupported("未找到可用的 WAN 连接。") }
        var entries: [DDNSEntry] = []
        for wan in wans {
            let rows = try await nodes.child(root: wan.ddnsRoot, fields: [
                "enabled": "DDNSCfgEnabled",
                "provider": "DDNSProvider",
                "host": "DDNSHostName",
                "user": "DDNSUsername",
                "password": "DDNSPassword"
            ])
            for (offset, row) in rows.enumerated() {
                guard let index = row["child_node_idx"].nodeIndex ?? (rows.isEmpty ? nil : offset + 1) else {
                    throw CPEError.malformedResponse
                }
                entries.append(DDNSEntry(
                    wan: wan, index: index,
                    provider: row["provider"].text ?? "",
                    hostname: row["host"].text ?? "",
                    username: row["user"].text ?? "",
                    password: row["password"].text ?? "",
                    enabled: row["enabled"].text == "1"
                ))
            }
        }
        return entries.sorted { $0.wan.device == $1.wan.device ? $0.index < $1.index : $0.wan.device < $1.wan.device }
    }

    @discardableResult
    public func add(_ input: DDNSInput) async throws -> DDNSEntry {
        if let error = input.validationError { throw CPEError.unsupported(error) }
        let nodes = FirmwareNodes(rpc: rpc)
        let index = try await nodes.add(root: input.wan.ddnsRoot, key: "ddns")
        let base = "\(input.wan.ddnsRoot).\(index)."
        try await nodes.setMulti([
            (base + "DDNSCfgEnabled", input.enabled ? "1" : "0"),
            (base + "DDNSProvider", input.provider),
            (base + "DDNSHostName", input.hostname),
            (base + "DDNSUsername", input.username),
            (base + "DDNSPassword", input.password)
        ])
        return try await verify(wan: input.wan, index: index, expectedHost: input.hostname)
    }

    @discardableResult
    public func update(_ entry: DDNSEntry, with input: DDNSInput) async throws -> DDNSEntry {
        if let error = input.validationError { throw CPEError.unsupported(error) }
        guard entry.wan == input.wan else { throw CPEError.unsupported("DDNS 条目所属 WAN 不一致。") }
        let nodes = FirmwareNodes(rpc: rpc)
        let base = "\(entry.wan.ddnsRoot).\(entry.index)."
        try await nodes.setMulti([
            (base + "DDNSCfgEnabled", input.enabled ? "1" : "0"),
            (base + "DDNSProvider", input.provider),
            (base + "DDNSHostName", input.hostname),
            (base + "DDNSUsername", input.username),
            (base + "DDNSPassword", input.password)
        ])
        return try await verify(wan: entry.wan, index: entry.index, expectedHost: input.hostname)
    }

    public func delete(_ entry: DDNSEntry) async throws {
        try await FirmwareNodes(rpc: rpc).delete(root: entry.wan.ddnsRoot, index: entry.index)
        let remaining = try await read()
        guard !remaining.contains(where: { $0.wan == entry.wan && $0.index == entry.index }) else {
            throw CPEError.uncertain
        }
    }

    @discardableResult
    public func setEnabled(_ entry: DDNSEntry, _ enabled: Bool) async throws -> DDNSEntry {
        let base = "\(entry.wan.ddnsRoot).\(entry.index)."
        try await FirmwareNodes(rpc: rpc).setSingle(base + "DDNSCfgEnabled", enabled ? "1" : "0")
        let updated = try await read()
        guard let saved = updated.first(where: { $0.wan == entry.wan && $0.index == entry.index }),
              saved.enabled == enabled else { throw CPEError.uncertain }
        return saved
    }

    private func verify(wan: WANConnectionRef, index: Int, expectedHost: String) async throws -> DDNSEntry {
        let entries = try await read()
        guard let saved = entries.first(where: { $0.wan == wan && $0.index == index }),
              saved.hostname == expectedHost else { throw CPEError.uncertain }
        return saved
    }
}

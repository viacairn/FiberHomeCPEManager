import Foundation

public enum CPEError: Error, LocalizedError, Sendable {
    case invalidAddress, malformedResponse, unsupported(String), authentication, busy, uncertain, rejected, crypto
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入 HTTP/HTTPS 管理地址，不包含账号、路径或查询参数。"
        case .malformedResponse: "设备响应格式不符合已验证协议，已停止操作。"
        case .unsupported(let reason): reason
        case .authentication: "登录失败或会话已失效，请检查账号密码后重新连接。"
        case .busy: "另一项操作正在进行，请稍后重试。"
        case .uncertain: "请求结果待确认，请刷新设备状态。不会自动重发。"
        case .rejected: "设备拒绝了操作，配置未确认生效。"
        case .crypto: "设备加密协商不匹配，未继续发送凭据。"
        case .http(let code): "设备返回 HTTP \(code)。请检查地址、权限及连接。"
        }
    }
}
public struct DeviceAddress: Hashable, Sendable, Codable {
    public let url: URL
    public init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = value.contains("://") ? value : "http://" + value
        guard var parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", (1...65535).contains(parts.port ?? 80) else { throw CPEError.invalidAddress }
        parts.path = ""; parts.scheme = parts.scheme?.lowercased()
        guard let url = parts.url else { throw CPEError.invalidAddress }
        self.url = url
    }
}
public struct Credentials: Codable, Sendable {
    public var address: String; public var username: String; public var password: String
    public init(address: String, username: String, password: String) { self.address = address; self.username = username; self.password = password }
}
public struct CapabilitySet: Sendable {
    public var radio = false, traffic = false, devices = false, bands = false, cells = false, fan = false, sms = false, reboot = false
    public init() {}
}
public struct RadioReading: Sendable {
    public var rsrp: String?, rsrq: String?, sinr: String?, band: String?, pci: String?, cell: String?
    public init() {}
}
public struct ConnectedDevice: Identifiable, Sendable {
    public var id: String; public var name: String; public var ip: String; public var interface: String
    public init(id: String, name: String, ip: String, interface: String) { self.id = id; self.name = name; self.ip = ip; self.interface = interface }
}
public struct SMSMessage: Identifiable, Sendable {
    public var id: String, sender: String, body: String, date: String
    public init(id: String, sender: String, body: String, date: String) { self.id = id; self.sender = sender; self.body = body; self.date = date }
}
public struct DeviceSnapshot: Sendable {
    public var model = "", firmware = "", network = "", uptime: String?
    public var lte = RadioReading(), nr = RadioReading()
    public var download: Double?, upload: Double?, todayBytes: Double?, monthBytes: Double?, temperature: String?
    public var receivedBytes: UInt64?, sentBytes: UInt64?
    public var devicesKnown = false
    public var devices: [ConnectedDevice] = []
    public var updated = Date()
    public init() {}
}
public enum LockMode: Equatable, Sendable {
    case automatic, bands(lte: [Int], nr: [Int]), cell(rat: Int, arfcn: Int, pci: Int), unknown
    public var title: String {
        switch self { case .automatic: "自动"; case .bands: "锁频段"; case .cell: "锁小区"; case .unknown: "待确认" }
    }
}
public struct TrafficCounter: Sendable {
    private var last: (UInt64, TimeInterval)?
    public init() {}
    public mutating func update(bytes: UInt64, time: TimeInterval) -> Double? {
        defer { last = (bytes, time) }
        guard let (previous, previousTime) = last, time > previousTime, bytes >= previous else { return nil }
        return Double(bytes - previous) / (time - previousTime)
    }
}

import Foundation

public enum CPEError: Error, LocalizedError, Sendable, Equatable {
    case invalidAddress, malformedResponse, unsupported(String), authentication, busy, uncertain, rejected, crypto
    case http(Int)
    /// The firmware rejected the login and named a reason; the message is its own wording.
    case loginRejected(String)
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
        case .loginRejected(let message): message
        }
    }
}

public extension DeviceAddress {
    /// Host and (non-default) port, without scheme or path.
    ///
    /// The connection form asks for a bare LAN IP; this is both what it shows and what the
    /// footer prints next to the model name.
    var hostText: String {
        let host = url.host ?? ""
        if let port = url.port, port != 80, port != 443 { return "\(host):\(port)" }
        return host
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
    /// True when the management console is plain HTTP. The device transport has no
    /// independent TLS layer in that case, so credentials cross the LAN in cleartext.
    public var isCleartext: Bool { url.scheme?.lowercased() == "http" }
}

public struct Credentials: Codable, Sendable, Equatable {
    public var address: String; public var username: String; public var password: String
    public init(address: String, username: String, password: String) {
        self.address = address; self.username = username; self.password = password
    }
}

/// Which access path a host uses. Derived from firmware interface nodes, never from names.
public enum AccessKind: String, Sendable, CaseIterable, Codable {
    case wired, wifi5G, wifi24G, unknown
    public var title: String {
        switch self {
        case .wired: "以太网"
        case .wifi5G: "5.0Ghz"
        case .wifi24G: "2.4Ghz"
        case .unknown: "未知接入"
        }
    }
    public var filterTitle: String {
        switch self {
        case .wired: "以太网"
        case .wifi5G: "5.0Ghz"
        case .wifi24G: "2.4Ghz"
        case .unknown: "未知接入"
        }
    }
    public var symbol: String {
        switch self {
        case .wired: "cable.connector"
        case .wifi5G, .wifi24G: "wifi"
        case .unknown: "questionmark.circle"
        }
    }
}

public struct ConnectedDevice: Identifiable, Sendable, Codable, Equatable {
    public var id: String; public var name: String; public var ip: String
    public var access: AccessKind
    public var mac: String?
    public var hostname: String?
    public var deviceType: String?
    public var onlineSeconds: TimeInterval?
    public enum Icon: Sendable {
        case laptop, phone, tablet, tv, gamepad, desktop, unknown
        // Appliances the panel actually sees on this network.
        case vacuum, washer, camera, airConditioner, hood, heater, watch
    }
    /// Icon inference.
    ///
    /// Hostname keywords win over `deviceType`, because this firmware reports `Phone` for
    /// cameras and air conditioners — letting the reported type win made every appliance
    /// render as a phone.
    public var icon: Icon {
        // Search both fields: the firmware sometimes reports a generic hostname while the
        // display name carries the meaningful model string.
        let n = (name + " " + (hostname ?? "")).lowercased()

        // Roborock H1 / H1 Air / WM series are washer-dryers, not robot vacuums.
        if n.contains("roborock-wm") || n.contains("-wm-") || n.contains("h1-air")
            || n.contains("h1 air") || n.contains("washer") || n.contains("洗衣") {
            return .washer
        }
        if n.contains("roborock") || n.contains("robot") || n.contains("vacuum") || n.contains("扫地") { return .vacuum }
        if n.contains("camera") || n.contains("cam-") || n.contains("摄像") { return .camera }
        if n.contains("airconditioner") || n.contains("air-conditioner") || n.contains("aircon")
            || n.contains("空调") { return .airConditioner }
        if n.contains("rangehood") || n.contains("hood") || n.contains("烟机") { return .hood }
        if n.contains("heater") || n.contains("热水器") || n.contains("waterheater") { return .heater }
        if n.contains("watch") || n.contains("手表") { return .watch }
        if n.contains("iphone") || n.contains("手机") { return .phone }
        if n.contains("ipad") || n.contains("平板") { return .tablet }
        if n.contains("macbook") || n.contains("laptop") || n.contains("笔记本") { return .laptop }
        // Matches "Mac", "Mac-mini", "iMac"; "MacBook" was handled above.
        if n.contains("mac") || n.contains("desktop") || n.contains("电脑") { return .desktop }
        if n.contains("tv") || n.contains("电视") { return .tv }
        if n.contains("switch") || n.contains("playstation") || n.contains("xbox") || n.contains("游戏") { return .gamepad }
        if n.contains("phone") || n.contains("mobile") { return .phone }
        if n.contains("pad") { return .tablet }

        // Fall back to what the firmware claims.
        if let type = deviceType?.lowercased() {
            if type.contains("phone") || type.contains("mobile") { return .phone }
            if type.contains("tablet") || type.contains("pad") { return .tablet }
            if type.contains("tv") { return .tv }
            if type.contains("game") || type.contains("console") { return .gamepad }
            if type.contains("laptop") || type.contains("macbook") { return .laptop }
            if type.contains("desktop") || type.contains("pc") { return .desktop }
        }
        return .unknown
    }

    public var systemSymbol: String {
        switch icon {
        case .laptop: "laptopcomputer"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .tv: "tv"
        case .gamepad: "gamecontroller"
        case .desktop: "desktopcomputer"
        case .watch: "applewatch"
        case .vacuum: "fan.floor"
        case .washer: "washer"
        case .camera: "web.camera"
        case .airConditioner: "air.conditioner.horizontal"
        case .hood: "wind"
        case .heater: "flame"
        case .unknown: "questionmark.square.dashed"
        }
    }
    public init(id: String, name: String, ip: String, access: AccessKind,
                mac: String? = nil, hostname: String? = nil, deviceType: String? = nil, onlineSeconds: TimeInterval? = nil) {
        self.id = id; self.name = name; self.ip = ip; self.access = access
        self.mac = mac; self.hostname = hostname; self.deviceType = deviceType; self.onlineSeconds = onlineSeconds
    }
}

/// One SMS conversation, grouped by the remote number — the same shape the firmware's
/// `get_sms_data` returns and the web UI displays.
public struct SMSThread: Identifiable, Sendable, Equatable {
    public var id: String { phone }
    public let phone: String
    public var messages: [SMSMessage]

    public init(phone: String, messages: [SMSMessage]) {
        self.phone = phone
        self.messages = messages
    }

    public var lastMessage: SMSMessage? { messages.last }
    public var unreadCount: Int { messages.filter { !$0.isRead && !$0.isSent }.count }
    public var preview: String {
        guard let last = lastMessage else { return "" }
        let oneLine = last.body.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
    }
}

public struct SMSMessage: Identifiable, Sendable, Codable, Equatable {
    public var id: String, sender: String, body: String, date: String
    public var isRead: Bool, isSent: Bool
    /// Raw firmware `childnode` index under `SMS_RecvMsg.{i}` or `SMS_SendMsg.{i}`.
    public var childnode: String?
    public init(id: String, sender: String, body: String, date: String,
                isRead: Bool = false, isSent: Bool = false, childnode: String? = nil) {
        self.id = id; self.sender = sender; self.body = body; self.date = date
        self.isRead = isRead; self.isSent = isSent; self.childnode = childnode ?? id
    }
}

/// One cellular radio's current reading. Values are raw firmware strings; the UI decides
/// formatting and never fabricates a value the device did not return.
public struct RadioReading: Sendable, Codable, Equatable {
    public var rsrp: String?, rsrq: String?, sinr: String?, rssi: String?
    public var band: String?, pci: String?, cell: String?
    public var arfcn: String?, scs: String?, mimo: String?, cqi: String?, power: String?
    public var tac: String?, plmn: String?, qci: String?
    /// Advertised aggregate bit rates, in kbit/s, as the firmware reports them.
    public var dlAmbrKbps: Double?, ulAmbrKbps: Double?
    public init() {}
    public var hasAnyValue: Bool {
        [rsrp, rsrq, sinr, band, pci, cell, arfcn].contains { $0 != nil }
    }
}

public enum RadioTech: String, Sendable, Codable {
    case nr, lte, wcdma, unknown
    public var title: String {
        switch self { case .nr: "5G"; case .lte: "4G"; case .wcdma: "3G"; case .unknown: "—" }
    }
}

/// The uplink path currently carrying traffic. Exactly one is active at a time.
/// Registration state shown in the overview hero card.
///
/// "Searching" and "not ready" are different problems: one means the modem sees a cell but
/// has no usable uplink, the other means there is nothing to attach to.
public enum Readiness: String, Sendable {
    case registered, searching, notReady

    public static func derive(uplinkAvailable: Bool, signalBars: Int?) -> Readiness {
        if uplinkAvailable { return .registered }
        if let bars = signalBars, bars > 0 { return .searching }
        return .notReady
    }

    public var title: String {
        switch self {
        case .registered: "已注册"
        case .searching: "搜索中"
        case .notReady: "未就绪"
        }
    }
}

/// PLMN → operator name, using the mainland China assignments the device reports.
///
/// The panel shows the operator instead of a bare `46001`, which is what a user recognizes.
public enum CarrierMapper {
    public static func displayName(for plmn: String?) -> String {
        guard let plmn, !plmn.isEmpty, plmn != "—" else { return "未知运营商" }
        switch plmn {
        case "46000", "46002", "46004", "46007", "46008": return "中国移动"
        case "46001", "46006", "46009": return "中国联通"
        case "46003", "46005", "46011": return "中国电信"
        case "46015": return "中国广电"
        default: return "PLMN \(plmn)"
        }
    }

    public static func title(for plmn: String?) -> String {
        guard let plmn, !plmn.isEmpty, plmn != "—" else { return "未知运营商" }
        return "\(displayName(for: plmn)) (\(plmn))"
    }
}

public enum UplinkMode: String, Sendable, Codable, CaseIterable {
    case cellular, broadband, aggregation, masterSlave, unknown
    public var title: String {
        switch self {
        case .cellular: "蜂窝上行"
        case .broadband: "以太网上行"
        case .aggregation: "双网聚合"
        case .masterSlave: "自动切换"
        case .unknown: "上行待确认"
        }
    }
}

public struct CellRecord: Identifiable, Sendable, Codable, Equatable {
    public var id: String { "\(tech.rawValue)-\(band)-\(pci)" }
    public var tech: RadioTech
    public var band: String
    public var pci: String
    public var channel: String?
    public var rsrp: String?
    public var sinr: String?
    public var state: State
    public enum State: String, Sendable, Codable {
        case serving, neighbor, unconnected
        public var title: String {
            switch self { case .serving: "服务中"; case .neighbor: "邻区"; case .unconnected: "未接入" }
        }
    }
    public init(tech: RadioTech, band: String, pci: String, channel: String? = nil,
                rsrp: String? = nil, sinr: String? = nil, state: State) {
        self.tech = tech; self.band = band; self.pci = pci; self.channel = channel
        self.rsrp = rsrp; self.sinr = sinr; self.state = state
    }
}

/// Device-wide snapshot. This is the value shared with the widget extension, so it
/// must never carry credentials, message bodies or host MAC addresses.
/// One carrier in the aggregation set: the primary cell or a secondary cell.
public struct CarrierComponent: Sendable, Codable, Equatable, Identifiable {
    public enum Role: String, Sendable, Codable { case primary, secondary }
    public var role: Role
    /// 1-based index among secondary carriers; 0 for the primary.
    public var index: Int
    public var band: String?
    public var pci: String?
    public var arfcn: String?
    public var state: String?

    public var id: String { "\(role.rawValue)\(index)" }

    public init(role: Role, index: Int = 0, band: String? = nil,
                pci: String? = nil, arfcn: String? = nil, state: String? = nil) {
        self.role = role; self.index = index
        self.band = band; self.pci = pci; self.arfcn = arfcn; self.state = state
    }

    /// A secondary carrier only counts when the modem reports something for it.
    public var isPresent: Bool {
        let fields = [band, pci, arfcn].compactMap { $0 }
        return fields.contains { !$0.isEmpty && $0 != "-" && $0 != "NULL" }
    }
}

public struct DeviceSnapshot: Sendable, Codable, Equatable {
    public var model = "", firmware = "", network = "", uptime: String?
    public var manufacturer: String?, hardware: String?
    public var operatorName: String?, plmn: String?
    /// "SA" / "NSA" networking architecture, when the firmware reports one.
    public var nrMode: String?
    /// Identifies which cellular radio is currently serving data.
    public var activeTech: RadioTech = .unknown
    public var uplink: UplinkMode = .unknown
    /// True only when firmware evidence confirms the current uplink is usable.
    /// On this firmware the proof is the WAN connection state, not SIM flags.
    public var uplinkAvailable = false
    /// Short, user-visible reason behind the uplink lamp.
    public var uplinkEvidence: String?
    public var wanConnected = false
    /// True only when WANDevice.2 reports `Connected`. An unplugged port reads `Unconfigured`.
    public var ethernetConnected = false
    /// External address on the Ethernet WAN (WANDevice.2); nil while it is not connected.
    public var ethernetAddress: String?
    public var wanAddress: String?
    public var wanUptime: Double?
    /// Raw `FanAutoConfig.mode` value (`0` standard, `1` silent, `2` performance).
    public var fanModeRaw: String?
    public var fanMode: FanMode? { fanModeRaw.flatMap(FanMode.init(rawValue:)) }
    /// WANDevice.1 is the cellular WAN on this firmware.
    public var cellularConnected: Bool { wanConnected }
    /// Number of SMS the device reports holding. Reading bodies is still unverified.
    public var smsCount: Int?
    /// 0...4 filled bars, nil when the device returned no usable signal metric.
    public var signalBars: Int?
    /// Primary carrier plus any attached secondary carriers, from `NetworkInfo`.
    public var carriers: [CarrierComponent] = []
    /// Serving cell plus any index-aligned neighbour cells from `*_NBR` fields.
    public var cells: [CellRecord] = []

    /// Secondary carriers the modem actually reports.
    public var secondaryCarriers: [CarrierComponent] {
        carriers.filter { $0.role == .secondary && $0.isPresent }
    }

    /// Total aggregated carriers, or nil when the firmware did not answer at all.
    public var carrierCount: Int? {
        guard let primary = carriers.first(where: { $0.role == .primary }) else { return nil }
        guard primary.isPresent || !secondaryCarriers.isEmpty else { return nil }
        return 1 + secondaryCarriers.count
    }

    public var carrierAggregationLabel: String {
        let count = carrierCount ?? 1
        return count <= 1 ? "单载波 PCC" : "载波聚合 \(count)CC"
    }
    public var nr = RadioReading(), lte = RadioReading()
    // Throughput in bits per second, derived from byte counters. nil means "not sampled".
    public var downloadBps: Double?, uploadBps: Double?
    public var todayBytes: Double?, monthBytes: Double?
    public var todayKnown = false, monthKnown = false
    public var temperature: String?
    /// Raw byte counters are kept only for internal sample deltas; not shown in UI.
    public var receivedBytes: UInt64?, sentBytes: UInt64?
    /// Instantaneous throughput reported by the firmware, in bytes per second.
    ///
    /// `TrafficStats.SpeedRxBytes` / `SpeedTxBytes` update continuously and match the
    /// observed byte-counter delta (measured 8.9 MB/s instantaneous vs 13.3 MB/s average
    /// during a 60 MB download). The `TodayTotal*` counters only refresh every few seconds,
    /// which made the UI show a constant "0 Kbps" during real traffic.
    public var rxBytesPerSecond: Double?, txBytesPerSecond: Double?
    public var devicesKnown = false
    public var deviceCount: Int?
    public var updated = Date()
    public var lockMode: LockMode = .automatic
    /// Cell-lock candidate list, populated only while `LockEnable` is on.
    public var lockedCells: [LockedCell] = []
    /// Capability gates: a disabled control means the firmware contract is unverified.
    public var capabilities = CapabilitySet()

    public var servingRadio: RadioReading {
        switch activeTech { case .nr: nr; case .lte: lte; default: nr.hasAnyValue ? nr : lte }
    }
    public init() {}
}

public enum LockMode: Equatable, Sendable, Codable {
    case automatic, bands(lte: [Int], nr: [Int]), cell(rat: Int, arfcn: Int, pci: Int?), unknown
    public var title: String {
        switch self {
        case .automatic: "自动选网"
        case .bands: "锁频段"
        case .cell: "锁小区"
        case .unknown: "待确认"
        }
    }
    public var isAutomatic: Bool { self == .automatic }
}

/// One entry of `X_FH_MobileNetwork.LockCellList.LockCell.{i}.`.
///
/// The firmware keeps a candidate list (up to 20) plus one `LockEnable` switch; there is
/// no single PCI/ARFCN field. `act` is `1` for LTE and `2` for NR.
public struct LockedCell: Sendable, Codable, Equatable, Identifiable {
    public var index: Int
    public var act: Int
    public var arfcn: Int
    /// A nil PCI is the stock page's empty string: match any PCI on this frequency.
    public var pci: Int?
    public var id: Int { index }
    public var techTitle: String { act == 1 ? "4G LTE" : "5G NR" }
    public var pciWireValue: String { pci.map(String.init) ?? "" }
    public var pciDisplay: String { pci.map(String.init) ?? "任意" }

    public init(index: Int, act: Int, arfcn: Int, pci: Int?) {
        self.index = index; self.act = act; self.arfcn = arfcn; self.pci = pci
    }
}

/// `X_FH_MobileNetwork.FanAutoConfig.mode`, enumerated by the stock fan page.
public enum FanMode: String, Sendable, Codable, CaseIterable {
    case standard = "0", silent = "1", performance = "2"

    public var title: String {
        switch self {
        case .standard: "标准模式"
        case .silent: "静音模式"
        case .performance: "性能模式"
        }
    }

    public var detail: String {
        switch self {
        case .standard: "平衡散热与静音，适合日常使用"
        case .silent: "降低噪音，适合低负载或低室温"
        case .performance: "强劲散热，适合高负载或高室温"
        }
    }
}


public struct CapabilitySet: Sendable, Codable, Equatable {
    public var radio = true, traffic = true, devices = true
    public var bands = false, cells = false, fan = false, sms = false, reboot = false
    public init() {}
    public init(bands: Bool = false, cells: Bool = false, fan: Bool = false, sms: Bool = false, reboot: Bool = false) {
        self.bands = bands; self.cells = cells; self.fan = fan; self.sms = sms; self.reboot = reboot
    }
}

/// Derives instantaneous throughput from a monotonically increasing byte counter.
/// Counters that go backwards are treated as resets, never as negative speed.
public struct TrafficCounter: Sendable {
    private var last: (UInt64, TimeInterval)?
    public init() {}
    public mutating func update(bytes: UInt64, time: TimeInterval) -> Double? {
        defer { last = (bytes, time) }
        guard let (previous, previousTime) = last, time > previousTime, bytes >= previous else { return nil }
        return Double(bytes - previous) / (time - previousTime)
    }
}

// MARK: - Formatting helpers (shared by app and widgets)

public enum MetricFormatter {
    /// Decimal bit-rate prefixes: Kbps / Mbps / Gbps, at most three significant digits.
    /// The unit is promoted on rounding overflow so "1000 Kbps" never appears.
    public static func bitRate(_ bitsPerSecond: Double?) -> (value: String, unit: String)? {
        guard let bps = bitsPerSecond, bps.isFinite, bps >= 0 else { return nil }
        // The design fixes the vocabulary at Kbps / Mbps / Gbps. A raw "bps" unit would
        // widen the menu-bar string and is not part of the spec, so small rates start at
        // Kbps: 0 → "0 Kbps", 400 → "0.4 Kbps".
        let units = ["Kbps", "Mbps", "Gbps", "Tbps"]
        var value = bps / 1000
        var index = 0
        while value >= 1000, index < units.count - 1 { value /= 1000; index += 1 }
        var text = significant(value)
        // Rounding may push the displayed value to 1000; promote the unit instead.
        if text == "1000", index < units.count - 1 {
            value /= 1000; index += 1; text = significant(value)
        }
        return (text, units[index])
    }
    /// Three significant digits without trailing zeros: 12.83 → "12.8", 102.4 → "102".
    public static func significant(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value == 0 { return "0" }
        if value >= 100 { return String(Int(value.rounded())) }
        if value >= 10 { return trimmed(value, digits: 1) }
        return trimmed(value, digits: 2)
    }
    private static func trimmed(_ value: Double, digits: Int) -> String {
        let text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            var t = text
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }
        return text
    }
    /// Decimal byte traffic: B / KB / MB / GB / TB, three significant digits.
    public static func bytes(_ value: Double?) -> (value: String, unit: String)? {
        guard let bytes = value, bytes.isFinite, bytes >= 0 else { return nil }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaled = bytes, index = 0
        while scaled >= 1000, index < units.count - 1 { scaled /= 1000; index += 1 }
        var text = significant(scaled)
        if text == "1000", index < units.count - 1 { scaled /= 1000; index += 1; text = significant(scaled) }
        return (text, units[index])
    }
    /// Maps RSRP/SINR evidence to 0–4 bars. Returns nil rather than guessing when the
    /// device exposes no recognised metric.
    public static func bars(rsrp: Double?, sinr: Double?, isNR: Bool) -> Int? {
        // NR SSB-RSRP and LTE RSRP share practical thresholds for a compact indicator.
        guard let rsrp else {
            if let sinr { return sinrBars(sinr) }
            return nil
        }
        let bands: [(ClosedRange<Double>?, Int)] = [
            (nil, isNR ? 1 : 0),          // below -115: 1 bar on NR, none on LTE
            ((-115.0)...(-105.0), 1),
            ((-105.0)...(-95.0), 2),
            ((-95.0)...(-85.0), 3),
            ((-85.0)...(-1.0), 4)
        ]
        for (range, bars) in bands {
            if let range, range.contains(rsrp) { return bars }
        }
        return rsrp < -125 ? 0 : nil
    }
    private static func sinrBars(_ sinr: Double) -> Int {
        switch sinr {
        case ..<0: 0
        case 0..<5: 1
        case 5..<13: 2
        case 13..<20: 3
        default: 4
        }
    }
    /// Parses numeric firmware strings that may carry units or thousands separators.
    public static func number(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let filtered = raw.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "dBm", with: "")
            .replacingOccurrences(of: "dB", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(filtered)
    }
    public static func formatDuration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds)
        let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分"
    }
}

/// Menu-bar label text. Separated from views so the same rule is unit-testable.
public enum MenuBarText {
    public static func label(for snapshot: DeviceSnapshot?, style: MenuBarStyle, stale: Bool) -> String {
        // Icon-only and signal-only styles have no text cell; emitting a dash there would
        // draw a stray character next to the bars.
        guard let snapshot else {
            return style == .signalAndRate ? "—" : ""
        }
        if stale { return "—" }
        switch style {
        // The segment already draws the bars; the text cell stays empty so the item keeps
        // its reserved width in this style too.
        case .signalOnly: return ""
        case .signalAndRate:
            // No sample yet (first second after connect) or no live rate: show the same
            // em dash the rest of the UI uses, never a bar count in the rate cell.
            guard let rate = MetricFormatter.bitRate(snapshot.downloadBps) else { return "—" }
            return "\(rate.value) \(rate.unit)"
        }
    }
    static func signalText(_ snapshot: DeviceSnapshot) -> String {
        guard let bars = snapshot.signalBars else { return "—" }
        return bars == 0 ? "—" : "\(bars)/4"
    }
}

/// What the menu-bar segment shows. Two modes only: signal strength, or signal strength
/// plus the current rate. An icon-only mode was removed — it hid the very thing the item
/// exists for.
public enum MenuBarStyle: Int, Sendable, CaseIterable, Codable {
    case signalAndRate = 0, signalOnly = 1

    public var title: String {
        switch self {
        case .signalAndRate: "显示下行网速"
        case .signalOnly: "仅信号强度"
        }
    }

    /// Whether the rate readout is shown; drives the menu's single checkbox item.
    public var showsRate: Bool { self == .signalAndRate }

    /// The product default is signal-only; the rate readout is a manual opt-in.
    public static let `default`: MenuBarStyle = .signalOnly

    /// A stored value from a build that still had the icon-only mode falls back to the
    /// default rather than crashing or showing nothing.
    public static func stored(_ raw: Int) -> MenuBarStyle {
        MenuBarStyle(rawValue: raw) ?? .default
    }
}

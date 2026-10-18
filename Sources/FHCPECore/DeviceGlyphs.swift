import Foundation

/// Icons a user can pin onto a host, covering the appliances this LAN actually has.
public enum DeviceGlyph: String, CaseIterable, Codable, Sendable {
    case vacuum, camera, airConditioner, airPurifier, washer, dryer, refrigerator
    case microwave, dishwasher, waterHeater, hood, router, tv, speaker, gamepad
    case laptop, desktop, phone, androidPhone, watch

    public var title: String {
        switch self {
        case .vacuum: "Demo-Device-b98d85"
        case .camera: "摄像头"
        case .airConditioner: "空调"
        case .airPurifier: "空气净化器"
        case .washer: "洗衣机"
        case .dryer: "烘干机"
        case .refrigerator: "冰箱"
        case .microwave: "微波炉"
        case .dishwasher: "洗碗机"
        case .waterHeater: "燃气热水器"
        case .hood: "油烟机"
        case .router: "路由器"
        case .tv: "电视"
        case .speaker: "音箱"
        case .gamepad: "游戏机"
        case .laptop: "笔记本电脑"
        case .desktop: "台式电脑"
        case .phone: "手机"
        case .androidPhone: "安卓手机"
        case .watch: "手表"
        }
    }

    public var symbol: String {
        switch self {
        case .vacuum: "fan.floor"
        case .camera: "web.camera"
        case .airConditioner: "air.conditioner.horizontal"
        case .airPurifier: "air.purifier"
        case .washer: "washer"
        case .dryer: "dryer"
        case .refrigerator: "refrigerator"
        case .microwave: "microwave"
        case .dishwasher: "dishwasher"
        case .waterHeater: "flame"
        case .hood: "wind"
        case .router: "wifi.router"
        case .tv: "tv"
        case .speaker: "hifispeaker"
        case .gamepad: "gamecontroller"
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .phone: "iphone"
        case .androidPhone: "smartphone"
        case .watch: "applewatch"
        }
    }
}

/// Per-host icon overrides, keyed by MAC address (falling back to hostname then name).
///
/// A pin is remembered for one month: if the same host has not appeared for 30 days the
/// entry is dropped, so a guest device that never comes back does not leave a stale icon
/// behind forever.
@MainActor
public struct DeviceGlyphStore {
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    private let storageKey = "deviceGlyphOverrides"

    public struct Entry: Codable, Sendable, Equatable {
        public var glyph: DeviceGlyph
        /// Last time this host was seen, used for expiry.
        public var lastSeen: Date
        /// Both stable aliases are retained, so a pin survives a DHCP/name change on either
        /// side: same MAC with a renamed host, or same hostname after a randomized MAC.
        public var mac: String?
        public var hostname: String?
        public init(glyph: DeviceGlyph, lastSeen: Date, mac: String? = nil, hostname: String? = nil) {
            self.glyph = glyph; self.lastSeen = lastSeen
            self.mac = mac; self.hostname = hostname
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Stable primary identity for a host: MAC wins, then hostname, then display name.
    public static func identity(of device: ConnectedDevice) -> String {
        if let mac = normalizedMAC(device.mac) {
            return "mac:" + mac
        }
        if let host = normalizedHost(device.hostname) {
            return "host:" + host
        }
        return "name:" + device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Every key a host can be recognised by. The primary key is used for storage; the
    /// others make the pin robust when only one of MAC/hostname changes.
    static func identityCandidates(of device: ConnectedDevice) -> [String] {
        var keys = [identity(of: device)]
        if let host = normalizedHost(device.hostname) {
            keys.append("host:" + host)
        }
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !name.isEmpty { keys.append("name:" + name) }
        return keys
    }

    private static func normalizedMAC(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private static func normalizedHost(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.lowercased()
    }

    /// True when the entry belongs to the device via its key, MAC or hostname.
    static func matches(entryKey: String, entry: Entry, device: ConnectedDevice) -> Bool {
        if identityCandidates(of: device).contains(entryKey) { return true }
        if let mac = normalizedMAC(device.mac), let entryMAC = entry.mac, mac == entryMAC {
            return true
        }
        if let host = normalizedHost(device.hostname),
           let entryHost = entry.hostname, host == entryHost {
            return true
        }
        return false
    }

    public func all() -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    public func glyph(for device: ConnectedDevice) -> DeviceGlyph? {
        let entries = all()
        let key = Self.identity(of: device)
        if let exact = entries[key] { return exact.glyph }
        return entries.first { Self.matches(entryKey: $0.key, entry: $0.value, device: device) }?.value.glyph
    }

    public func assign(_ glyph: DeviceGlyph?, to device: ConnectedDevice, now: Date = Date()) {
        var entries = all()
        let key = Self.identity(of: device)
        // Remove every alias of this host first, so changing a pinned icon cannot leave a
        // second entry behind under an old MAC/hostname and later resurrect it.
        for entryKey in Array(entries.keys) {
            guard let entry = entries[entryKey],
                  Self.matches(entryKey: entryKey, entry: entry, device: device) else { continue }
            entries.removeValue(forKey: entryKey)
        }
        if let glyph {
            entries[key] = Entry(glyph: glyph, lastSeen: now,
                                 mac: Self.normalizedMAC(device.mac),
                                 hostname: Self.normalizedHost(device.hostname))
        }
        save(entries)
    }

    /// Marks every host in devices as seen, then drops entries older than the retention
    /// window. Returns the number of removed entries. Matching uses both the MAC and the
    /// hostname alias, so a returning host keeps its pin even if one of them changed.
    @discardableResult
    public func prune(keeping devices: [ConnectedDevice], now: Date = Date()) -> Int {
        let original = all()
        guard !original.isEmpty else { return 0 }
        var entries = original
        for entryKey in Array(entries.keys) {
            guard let entry = entries[entryKey],
                  let host = devices.first(where: { Self.matches(entryKey: entryKey, entry: entry, device: $0) })
            else { continue }
            entries[entryKey]?.lastSeen = now
            // Refresh aliases from the currently observed host.
            if let mac = Self.normalizedMAC(host.mac) { entries[entryKey]?.mac = mac }
            if let name = Self.normalizedHost(host.hostname) { entries[entryKey]?.hostname = name }
        }
        let before = entries.count
        entries = entries.filter { _, entry in
            now.timeIntervalSince(entry.lastSeen) < Self.retention
        }
        if entries != original {
            save(entries)
        }
        return before - entries.count
    }
}

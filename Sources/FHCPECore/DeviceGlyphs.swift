import Foundation

/// General categories available when a user chooses a device's icon manually.
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

/// Per-host icon overrides, keyed by MAC address. Without a MAC, a hostname or name is
/// scoped to its current IP; an address change does not establish the same device.
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
        /// Identity metadata retained for existing saved pins. A known MAC must agree;
        /// a shared hostname does not establish that two MAC addresses are one device.
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

    /// MAC is the stable identity. Weak names are qualified by the current IP so two
    /// endpoints with a shared default name cannot share a manually selected icon.
    public static func identity(of device: ConnectedDevice) -> String {
        if let mac = normalizedMAC(device.mac) {
            return "mac:" + mac
        }
        let address = normalizedIP(device.ip) ?? ""
        if let host = normalizedHost(device.hostname) {
            return "host:" + host + "|ip:" + address
        }
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "name:" + name + "|ip:" + address
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

    private static func normalizedIP(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : value
    }

    /// A stored MAC key remains authoritative for legacy entries too, including entries
    /// whose metadata an older version refreshed through a shared hostname.
    private static func storedMAC(entryKey: String, entry: Entry) -> String? {
        if entryKey.hasPrefix("mac:") {
            return normalizedMAC(String(entryKey.dropFirst(4)))
        }
        return normalizedMAC(entry.mac)
    }

    /// MAC identity is decisive. A weak pin requires its name and current IP to agree.
    /// Legacy bare name/hostname keys have no address evidence and are not inherited.
    static func matches(entryKey: String, entry: Entry, device: ConnectedDevice) -> Bool {
        let mac = normalizedMAC(device.mac)
        let entryMAC = storedMAC(entryKey: entryKey, entry: entry)
        if mac != nil || entryMAC != nil {
            return mac != nil && mac == entryMAC
        }
        guard normalizedIP(device.ip) != nil else { return false }
        return entryKey == identity(of: device)
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
        glyph(for: device, in: all())
    }

    public func glyph(for device: ConnectedDevice, in entries: [String: Entry]) -> DeviceGlyph? {
        guard !entries.isEmpty else { return nil }
        let key = Self.identity(of: device)
        if let exact = entries[key], Self.matches(entryKey: key, entry: exact, device: device) {
            return exact.glyph
        }
        return entries.first { Self.matches(entryKey: $0.key, entry: $0.value, device: device) }?.value.glyph
    }

    public func assign(_ glyph: DeviceGlyph?, to device: ConnectedDevice, now: Date = Date()) {
        guard Self.normalizedMAC(device.mac) != nil || Self.normalizedIP(device.ip) != nil else { return }
        var entries = all()
        let key = Self.identity(of: device)
        // Remove only entries belonging to this identity. A reused hostname must not
        // replace or clear another MAC's manually chosen icon.
        for entryKey in Array(entries.keys) {
            guard let entry = entries[entryKey],
                  Self.matches(entryKey: entryKey, entry: entry, device: device) else { continue }
            entries.removeValue(forKey: entryKey)
        }
        if let glyph {
            // Older versions could attach a MAC to a hostname-keyed entry. Preserve that
            // device's pin before reusing its fallback key for a device without a MAC.
            if let displaced = entries[key], let mac = Self.storedMAC(entryKey: key, entry: displaced) {
                let macKey = "mac:" + mac
                if entries[macKey] == nil { entries[macKey] = displaced }
            }
            entries[key] = Entry(glyph: glyph, lastSeen: now,
                                 mac: Self.normalizedMAC(device.mac),
                                 hostname: Self.normalizedHost(device.hostname))
        }
        save(entries)
    }

    /// Marks every host in devices as seen, then drops entries older than the retention
    /// window. Returns the number of removed entries. A matching MAC survives DHCP/name
    /// changes; a shared hostname with a different MAC does not refresh the old entry.
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
            // Refresh metadata only after confirming the same device identity.
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

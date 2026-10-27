import Foundation

/// General categories available when a user chooses a device's icon manually.
public enum DeviceGlyph: String, CaseIterable, Codable, Sendable {
    case vacuum, camera, airConditioner, airPurifier, washer, dryer, refrigerator
    case microwave, dishwasher, waterHeater, hood, router, tv, speaker, gamepad
    case laptop, desktop, phone, androidPhone, watch

    public var title: String {
        switch self {
        case .vacuum: "扫地机器人"
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

/// User-selected device icons, keyed by a normalized MAC or the device identifier.
@MainActor
public struct DeviceGlyphStore {
    private let storageKey = "deviceGlyphOverrides"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func identity(of device: ConnectedDevice) -> String {
        if let rawMAC = device.mac {
            let mac = rawMAC.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mac.isEmpty { return mac.uppercased().replacingOccurrences(of: "-", with: ":") }
        }
        return device.id
    }

    public func all() -> [String: DeviceGlyph] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([String: DeviceGlyph].self, from: data)
        else { return [:] }
        return entries
    }

    public func glyph(for device: ConnectedDevice) -> DeviceGlyph? {
        glyph(for: device, in: all())
    }

    public func glyph(for device: ConnectedDevice, in entries: [String: DeviceGlyph]) -> DeviceGlyph? {
        entries[Self.identity(of: device)]
    }

    public func assign(_ glyph: DeviceGlyph?, to device: ConnectedDevice) {
        var entries = all()
        entries[Self.identity(of: device)] = glyph
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

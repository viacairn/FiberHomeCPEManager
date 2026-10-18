import Foundation

/// The minimal, non-sensitive status handed to the desktop widget extension.
///
/// This type is the contract between the menu-bar app and the widget: it intentionally
/// excludes credentials, session tokens, SMS bodies, device names, MAC addresses and IPs.
/// Only aggregate counters and radio metrics that the user already sees in the overview
/// are written to the shared App Group container.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case connected, stale, disconnected, unconfigured
    }
    public var state: State
    public var model: String
    public var network: String
    public var uplinkTitle: String
    public var uplinkAvailable: Bool
    public var signalBars: Int?
    public var downloadBps: Double?
    public var uploadBps: Double?
    public var todayBytes: Double?
    public var monthBytes: Double?
    public var deviceCount: Int?
    public var updated: Date
    public var latency: String?

    public init(state: State, model: String = "—", network: String = "—", uplinkTitle: String = "上行待确认",
                uplinkAvailable: Bool = false, signalBars: Int? = nil, downloadBps: Double? = nil,
                uploadBps: Double? = nil, todayBytes: Double? = nil, monthBytes: Double? = nil,
                deviceCount: Int? = nil, updated: Date = .now, latency: String? = nil) {
        self.state = state; self.model = model; self.network = network; self.uplinkTitle = uplinkTitle
        self.uplinkAvailable = uplinkAvailable; self.signalBars = signalBars; self.downloadBps = downloadBps
        self.uploadBps = uploadBps; self.todayBytes = todayBytes; self.monthBytes = monthBytes
        self.deviceCount = deviceCount; self.updated = updated; self.latency = latency
    }

    public static let unconfigured = WidgetSnapshot(state: .unconfigured)
    public static let disconnected = WidgetSnapshot(state: .disconnected)

    public init(snapshot: DeviceSnapshot, stale: Bool, latency: String? = nil) {
        self.init(
            state: stale ? .stale : .connected,
            model: snapshot.model.isEmpty ? "—" : snapshot.model,
            network: snapshot.network.isEmpty ? "—" : snapshot.network,
            uplinkTitle: snapshot.uplink.title,
            uplinkAvailable: snapshot.uplinkAvailable,
            signalBars: snapshot.signalBars,
            downloadBps: snapshot.downloadBps,
            uploadBps: snapshot.uploadBps,
            todayBytes: snapshot.todayBytes,
            monthBytes: snapshot.monthBytes,
            deviceCount: snapshot.deviceCount,
            updated: snapshot.updated,
            latency: latency
        )
    }

    /// A stale snapshot keeps its last readings for context but must not look live.
    public var effectiveState: State { state }

    /// True when values describe a live, freshly sampled session.
    public var isLive: Bool { state == .connected }
}

/// Writes and reads the widget contract inside the App Group container.
///
/// Apple's group-container contract requires the same identifier in both the app and
/// the extension entitlements. When the container cannot be opened (for example an
/// unsigned command-line invocation of the same code) every method degrades to a no-op
/// instead of falling back to a world-readable path.
public struct SharedSnapshotStore: Sendable {
    public static let appGroup = "group.local.fhcpem.app"
    public static let fileName = "widget-snapshot.json"

    private let directory: URL?
    public init(appGroup: String = SharedSnapshotStore.appGroup) {
        directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public var isAvailable: Bool { directory != nil }

    private var fileURL: URL? { directory?.appendingPathComponent(Self.fileName) }

    public func write(_ snapshot: WidgetSnapshot) {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            // `.atomic` prevents a widget refresh from reading a half-written file.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // Widget data is a convenience; failing to publish it must never interrupt
            // the authenticated session or surface a credential-adjacent error.
        }
    }

    public func read() -> WidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Display preferences live in the app's own defaults. They are non-secret: menu-bar
/// content choice and whether the user opted into remembering the connection.
public struct Preferences: Sendable {
    public enum Key {
        public static let menuBarStyle = "menuBarStyle"
        public static let rememberConnection = "rememberConnection"
    }
    /// `UserDefaults` is not `Sendable`, so the reference is wrapped rather than stored.
    private final class Box: @unchecked Sendable {
        let defaults: UserDefaults
        init(defaults: UserDefaults) { self.defaults = defaults }
    }
    private let box: Box
    public init(defaults: UserDefaults = .standard) { box = Box(defaults: defaults) }

    public var menuBarStyle: MenuBarStyle {
        get {
            // Absent key means "never chosen": fall back to the product default rather than
            // to rawValue 0.
            guard let raw = box.defaults.object(forKey: Key.menuBarStyle) as? Int else {
                return .default
            }
            return MenuBarStyle.stored(raw)
        }
        nonmutating set { box.defaults.set(newValue.rawValue, forKey: Key.menuBarStyle) }
    }

    /// Whether the user asked to keep the connection in the Keychain. Only the *intent*
    /// is stored here; the credential itself lives in the keychain item.
    public var rememberConnection: Bool {
        get { box.defaults.bool(forKey: Key.rememberConnection) }
        nonmutating set { box.defaults.set(newValue, forKey: Key.rememberConnection) }
    }
}

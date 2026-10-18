import Foundation

/// One refresh cycle: the aggregate snapshot plus the volatile device list.
///
/// The device list is deliberately kept *out* of `DeviceSnapshot` so the value written
/// to the widget container (see `WidgetSnapshot`) cannot accidentally carry host names,
/// MAC addresses or IPs.
public struct SessionReading: Sendable {
    public var snapshot: DeviceSnapshot
    public var devices: [ConnectedDevice]
    public init(snapshot: DeviceSnapshot, devices: [ConnectedDevice]) {
        self.snapshot = snapshot; self.devices = devices
    }
}

public actor DeviceSession {
    private let transport: LocalTransport
    private let adapter: LG6851Adapter
    private lazy var extended = LG6851ExtendedAdapter(rpc: transport)
    private lazy var radioLocks = RadioLockService(rpc: transport)
    private lazy var mobileNetwork = MobileNetworkService(rpc: transport)
    private lazy var ddnsService = DDNSService(rpc: transport)
    private lazy var portMappingService = PortMappingService(rpc: transport)
    private var refreshing = false
    private var receiveCounter = TrafficCounter()
    private var sendCounter = TrafficCounter()
    public init(address: DeviceAddress) {
        let transport = LocalTransport(address: address)
        self.transport = transport; adapter = LG6851Adapter(rpc: transport)
    }
    public func connect(username: String, password: String) async throws -> SessionReading {
        _ = try await adapter.identify()
        try await adapter.login(username: username, password: password)
        return try await sample()
    }
    public func refresh() async throws -> SessionReading {
        guard !refreshing else { throw CPEError.busy }
        refreshing = true
        defer { refreshing = false }
        return try await sample()
    }
    /// Reads the snapshot and derives bit-per-second rates from byte-counter deltas.
    /// The first sample after connect has no delta yet, so rates stay nil ("—").
    private func sample() async throws -> SessionReading {
        var value = try await adapter.snapshot()
        let devices = try await adapter.devices()
        value.devicesKnown = true
        value.deviceCount = devices.count
        let instant = ProcessInfo.processInfo.systemUptime
        // Prefer the firmware's instantaneous counters: they move on every poll, while the
        // daily totals update coarsely and would show 0 during real traffic. Fall back to a
        // byte-counter delta if a firmware revision does not expose the speed fields.
        let receiveDelta = value.receivedBytes.flatMap { receiveCounter.update(bytes: $0, time: instant) }
        let sendDelta = value.sentBytes.flatMap { sendCounter.update(bytes: $0, time: instant) }
        if let live = value.rxBytesPerSecond {
            value.downloadBps = max(0, live) * 8
        } else if let delta = receiveDelta {
            value.downloadBps = delta * 8
        }
        if let live = value.txBytesPerSecond {
            value.uploadBps = max(0, live) * 8
        } else if let delta = sendDelta {
            value.uploadBps = delta * 8
        }
        return SessionReading(snapshot: value, devices: devices)
    }
    /// Neighbour cells from the verified parallel arrays; no scan request is issued.
    public func discoverableCells() async throws -> [CellRecord] {
        try await extended.discoverableCells()
    }
    // MARK: SMS (verified against the live unit: `get_sms_data` / `send_msg`)

    public func threads() async throws -> [SMSThread] {
        try await extended.threads()
    }

    public func markRead(_ childnodes: [String]) async throws {
        try await extended.markRead(childnodes: childnodes)
    }

    @discardableResult
    public func sendSMS(to number: String, body: String) async throws -> Bool {
        try await extended.sendSMS(to: number, body: body)
    }

    // MARK: Settings (Wi-Fi / reboot / LED / fan / MLO)

    public func readSettings() async throws -> DeviceSettings {
        try await SettingsService(rpc: transport).read()
    }

    public func setSSIDEnabled(index: Int, enabled: Bool) async throws -> Bool {
        try await SettingsService(rpc: transport).setSSIDEnabled(index: index, enabled: enabled)
    }

    public func renameSSID(index: Int, ssid: String) async throws -> Bool {
        try await SettingsService(rpc: transport).renameSSID(index: index, ssid: ssid)
    }

    public func setTimedReboot(enabled: Bool, time: String, weekday: String) async throws -> Bool {
        try await SettingsService(rpc: transport).setTimedReboot(enabled: enabled, time: time, weekday: weekday)
    }

    public func setUplink(_ target: UplinkTarget) async throws -> Bool {
        let service = SettingsService(rpc: transport)
        return try await service.setUplink(target)
    }

    public func setLEDEnabled(_ enabled: Bool) async throws -> Bool {
        try await SettingsService(rpc: transport).setLEDEnabled(enabled)
    }

    public func setFanMode(_ mode: FanMode) async throws -> Bool {
        try await SettingsService(rpc: transport).setFanMode(mode)
    }

    public func readRadioLocks() async throws -> RadioLockState { try await radioLocks.read() }
    public func setCellLockEnabled(_ enabled: Bool) async throws -> RadioLockState {
        try await radioLocks.setCellLockEnabled(enabled)
    }
    public func setBandLockEnabled(_ enabled: Bool, lte: [Int], nr: [Int]) async throws -> RadioLockState {
        try await radioLocks.setBandLockEnabled(enabled, lte: lte, nr: nr)
    }
    public func disableRadioLocks() async throws -> RadioLockState { try await radioLocks.disableAll() }
    public func addLockedCell(_ cell: LockedCell) async throws -> RadioLockState {
        try await radioLocks.addCell(act: cell.act, arfcn: cell.arfcn, pci: cell.pci)
    }
    public func updateLockedCell(_ cell: LockedCell) async throws -> RadioLockState {
        try await radioLocks.updateCell(index: cell.index, act: cell.act, arfcn: cell.arfcn, pci: cell.pci)
    }
    public func deleteLockedCell(_ cell: LockedCell) async throws -> RadioLockState {
        try await radioLocks.deleteCell(index: cell.index)
    }
    public func reserveIP(mac: String, ip: String) async throws {
        _ = try await DHCPReservationService(rpc: transport).reserve(mac: mac, ip: ip)
    }

    public func readMobileNetwork() async throws -> MobileNetworkState { try await mobileNetwork.read() }
    public func readWANConnections() async throws -> [WANConnectionRef] { try await WANDiscovery.connections(transport) }
    public func setAirplaneMode(_ enabled: Bool) async throws -> MobileNetworkState {
        try await mobileNetwork.setAirplaneMode(enabled)
    }
    public func setCellularData(_ enabled: Bool) async throws -> MobileNetworkState {
        try await mobileNetwork.setCellularData(enabled)
    }
    public func setAntenna(enabled: Bool, type: AntennaType) async throws -> MobileNetworkState {
        try await mobileNetwork.setAntenna(enabled: enabled, type: type)
    }
    public func readDDNS() async throws -> [DDNSEntry] { try await ddnsService.read() }
    public func addDDNS(_ input: DDNSInput) async throws -> DDNSEntry { try await ddnsService.add(input) }
    public func updateDDNS(_ entry: DDNSEntry, with input: DDNSInput) async throws -> DDNSEntry {
        try await ddnsService.update(entry, with: input)
    }
    public func deleteDDNS(_ entry: DDNSEntry) async throws { try await ddnsService.delete(entry) }
    public func setDDNSEnabled(_ entry: DDNSEntry, _ enabled: Bool) async throws -> DDNSEntry {
        try await ddnsService.setEnabled(entry, enabled)
    }
    public func readPortMappings() async throws -> [PortMappingEntry] { try await portMappingService.read() }
    public func addPortMapping(_ input: PortMappingInput) async throws -> PortMappingEntry { try await portMappingService.add(input) }
    public func deletePortMapping(_ entry: PortMappingEntry) async throws { try await portMappingService.delete(entry) }
    public func setPortMappingEnabled(_ entry: PortMappingEntry, _ enabled: Bool) async throws -> PortMappingEntry {
        try await portMappingService.setEnabled(entry, enabled)
    }

    /// An outage must not turn a pre-outage counter into the next live speed sample.
    public func resetTrafficBaseline() {
        receiveCounter = TrafficCounter(); sendCounter = TrafficCounter()
    }

    /// Diagnostic hook: reads arbitrary firmware nodes by path.
    ///
    /// Used by the development probe to discover node names before they are wired into a
    /// shipped feature. Read-only by construction.
    public func probe(_ fields: [String: String]) async throws -> JSONValue {
        try await adapter.read(fields)
    }

    /// Diagnostic hook: single-node write, same call the device's settings pages use.
    ///
    /// Development only — the probe uses it to verify a write path before it is wired into
    /// a shipped feature.
    public func writeProbe(_ path: String, value: String) async throws -> JSONValue {
        try await transport.call("set_single_by_xmlnode",
                                 data: .object(["url": .string(path), "value": .string(value)]),
                                 publicAccess: false)
    }

    public func close() async { await transport.close() }
}

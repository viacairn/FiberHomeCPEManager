import Foundation

public actor DeviceSession {
    private let transport: LocalTransport
    private let adapter: LG6851Adapter
    private var busy = false
    private var receiveCounter = TrafficCounter()
    private var sendCounter = TrafficCounter()
    public init(address: DeviceAddress) {
        let transport = LocalTransport(address: address)
        self.transport = transport; adapter = LG6851Adapter(rpc: transport)
    }
    public func connect(username: String, password: String) async throws -> DeviceSnapshot {
        guard !busy else { throw CPEError.busy }; busy = true; defer { busy = false }
        _ = try await adapter.identify()
        try await adapter.login(username: username, password: password)
        return try await adapter.snapshot()
    }
    public func refresh() async throws -> DeviceSnapshot {
        guard !busy else { throw CPEError.busy }; busy = true; defer { busy = false }
        var value = try await adapter.snapshot()
        value.devices = try await adapter.devices()
        value.devicesKnown = true
        let instant = ProcessInfo.processInfo.systemUptime
        if let bytes = value.receivedBytes { value.download = receiveCounter.update(bytes: bytes, time: instant) }
        if let bytes = value.sentBytes { value.upload = sendCounter.update(bytes: bytes, time: instant) }
        return value
    }
    public func close() async { await transport.close() }
}

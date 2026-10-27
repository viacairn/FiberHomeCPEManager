import Foundation

public enum DHCPReservationError: Error, LocalizedError, Sendable, Equatable {
    case invalidMACAddress
    case invalidIPAddress

    public var errorDescription: String? {
        switch self {
        case .invalidMACAddress: "设备没有有效的 MAC 地址，无法设置固定 IP。"
        case .invalidIPAddress: "请输入有效的 IPv4 地址，例如 192.168.8.120。"
        }
    }
}

/// A DHCP address reservation on the router, keyed by a client's unicast MAC address.
public struct DHCPReservation: Sendable, Equatable {
    public let mac: String
    public let ip: String
    /// The firmware's `child_node_idx`; nil for a validated reservation not yet read back.
    public let index: Int?

    public init(mac: String, ip: String, index: Int? = nil) throws {
        let mac = mac.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let separator: Character = mac.contains(":") ? ":" : "-"
        let components = mac.split(separator: separator, omittingEmptySubsequences: false)
        guard components.count == 6,
              components.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy(Self.isHexDigit) }),
              let first = UInt8(components[0], radix: 16), first & 1 == 0,
              components.contains(where: { $0 != "00" }) else {
            throw DHCPReservationError.invalidMACAddress
        }
        let ip = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Self.ipv4Value(ip), value >> 24 != 0,
              value >> 24 != 127, value >> 24 < 224 else {
            throw DHCPReservationError.invalidIPAddress
        }
        self.mac = components.joined(separator: ":")
        self.ip = ip
        self.index = index
    }

    /// Firmware rows are displayed without applying user-input address restrictions.
    init(readMAC: String, ip: String, index: Int) {
        self.mac = readMAC.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().replacingOccurrences(of: "-", with: ":")
        self.ip = ip
        self.index = index
    }

    static func ipv4Value(_ text: String) -> UInt32? {
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        var value: UInt32 = 0
        for component in components {
            guard !component.isEmpty, component.utf8.allSatisfy({ (48...57).contains($0) }),
                  component.count == 1 || component.first != "0",
                  let octet = UInt8(component) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        return value
    }

    private static func isHexDigit(_ character: UInt8) -> Bool {
        (48...57).contains(character) || (65...70).contains(character)
    }
}

/// The stock `/network/lanSet/dhcpStaticSettings` contract from RP0112's own page source.
/// It adds `X_FH_StaticDhcp` entries or edits the existing instance, then refreshes the table.
public struct DHCPReservationService: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    public static let staticRoot = "LANDevice.1.LANHostConfigManagement.X_FH_StaticDhcp."
    public static let lanRoot = "LANDevice.1.LANHostConfigManagement."

    public func read() async throws -> [DHCPReservation] {
        let rows = try await FirmwareNodes(rpc: rpc).child(root: Self.staticRoot,
                                                         fields: ["mac": "MACAddress", "ip": "IPAddress"])
        var reservations: [DHCPReservation] = []
        var indices = Set<Int>()
        var macs = Set<String>()
        for row in rows {
            guard let index = row["child_node_idx"].nodeIndex,
                  let mac = row["mac"].text, let ip = row["ip"].text else { continue }
            let reservation = DHCPReservation(readMAC: mac, ip: ip, index: index)
            guard indices.insert(index).inserted, macs.insert(reservation.mac).inserted else { continue }
            reservations.append(reservation)
        }
        FirmwareNodes.reportSkippedRows(rows.count - reservations.count, table: "静态 IP 表")
        return reservations
    }

    @discardableResult
    public func reserve(mac: String, ip: String) async throws -> [DHCPReservation] {
        let requested = try DHCPReservation(mac: mac, ip: ip)
        let existing = try await read()
        let matching = existing.first { $0.mac == requested.mac }
        if matching?.ip == requested.ip { return existing }

        if let index = matching?.index {
            let entryRoot = Self.staticRoot + "\(index)."
            try await FirmwareNodes(rpc: rpc).setMulti([
                (entryRoot + "MACAddress", requested.mac),
                (entryRoot + "IPAddress", requested.ip)
            ])
        } else {
            let reply = try await rpc.call("add_set_xmlnode", data: .object([
                "url": .string(Self.staticRoot),
                "setNode": .object([
                    "url": .strings(["MAC": "MACAddress", "IP": "IPAddress"]),
                    "value": .strings(["MAC": requested.mac, "IP": requested.ip])
                ])
            ]), publicAccess: false)
            try FirmwareNodes.checkWriteReply(reply)
        }
        return try await read()
    }

    @discardableResult
    public func remove(_ reservation: DHCPReservation) async throws -> [DHCPReservation] {
        guard let index = reservation.index, index > 0 else { throw CPEError.malformedResponse }
        try await FirmwareNodes(rpc: rpc).delete(root: String(Self.staticRoot.dropLast()), index: index)
        return try await read()
    }
}

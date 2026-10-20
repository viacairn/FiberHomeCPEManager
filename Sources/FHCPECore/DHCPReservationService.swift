import Foundation

public enum DHCPReservationError: Error, LocalizedError, Sendable, Equatable {
    case invalidMACAddress
    case invalidIPAddress
    case dhcpDisabled
    case outsideAddressPool(min: String, max: String)
    case routerAddress
    case addressConflict

    public var errorDescription: String? {
        switch self {
        case .invalidMACAddress: "设备没有有效的 MAC 地址，无法设置固定 IP。"
        case .invalidIPAddress: "请输入有效的 IPv4 地址，例如 192.168.8.120。"
        case .dhcpDisabled: "路由器的 DHCP 服务已关闭，无法设置固定 IP。"
        case .outsideAddressPool(let min, let max): "固定 IP 必须在 DHCP 地址池 \(min)–\(max) 内。"
        case .routerAddress: "固定 IP 不能使用路由器的 LAN 地址。"
        case .addressConflict: "此 IP 已保留给另一台设备，请选择其他地址。"
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
/// It adds `X_FH_StaticDhcp` entries or edits the existing instance, then verifies the table.
public struct DHCPReservationService: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    public static let staticRoot = "LANDevice.1.LANHostConfigManagement.X_FH_StaticDhcp."
    public static let lanRoot = "LANDevice.1.LANHostConfigManagement."

    public func read() async throws -> [DHCPReservation] {
        let reply = try await rpc.call("get_xml_childnode_value", data: .object([
            "url": .string(Self.staticRoot),
            "node": .strings(["mac": "MACAddress", "ip": "IPAddress"])
        ]), publicAccess: false)
        guard case .array(let rows) = reply["data"] else { throw CPEError.malformedResponse }
        var reservations: [DHCPReservation] = []
        var indices = Set<Int>()
        var macs = Set<String>()
        for row in rows {
            guard let indexText = row["child_node_idx"].text,
                  indexText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let index = Int(indexText), index > 0, indices.insert(index).inserted,
                  let mac = row["mac"].text, let ip = row["ip"].text,
                  let reservation = try? DHCPReservation(mac: mac, ip: ip, index: index),
                  macs.insert(reservation.mac).inserted else { throw CPEError.malformedResponse }
            reservations.append(reservation)
        }
        return reservations
    }

    /// Writes at most once. A missing read-back match is uncertain and is never retried.
    @discardableResult
    public func reserve(mac: String, ip: String) async throws -> DHCPReservation {
        let requested = try DHCPReservation(mac: mac, ip: ip)
        try await validateAddressPool(requested.ip)
        let existing = try await read()
        guard !existing.contains(where: { $0.ip == requested.ip && $0.mac != requested.mac }) else {
            throw DHCPReservationError.addressConflict
        }
        let matching = existing.first { $0.mac == requested.mac }
        if let matching, matching.ip == requested.ip { return matching }

        let values = JSONValue.strings(["MAC": requested.mac, "IP": requested.ip])
        let method: String
        let data: JSONValue
        if let index = matching?.index {
            let entryRoot = Self.staticRoot + "\(index)."
            method = "set_value_by_xmlnode"
            data = .object([
                "url": .strings(["MAC": entryRoot + "MACAddress", "IP": entryRoot + "IPAddress"]),
                "value": values
            ])
        } else {
            method = "add_set_xmlnode"
            data = .object([
                "url": .string(Self.staticRoot),
                "setNode": .object([
                    "url": .strings(["MAC": "MACAddress", "IP": "IPAddress"]),
                    "value": values
                ])
            ])
        }
        let reply = try await rpc.call(method, data: data, publicAccess: false)
        try Self.checkWriteReply(reply)
        let confirmed = try await read()
        guard let saved = confirmed.first(where: { $0.mac == requested.mac && $0.ip == requested.ip }),
              !confirmed.contains(where: { $0.mac != requested.mac && $0.ip == requested.ip }) else {
            throw CPEError.uncertain
        }
        return saved
    }

    /// Delete only the exact binding that was read. Reused indices or another user's
    /// concurrent edit must never turn cleanup into deletion of a different binding.
    public func remove(_ reservation: DHCPReservation) async throws {
        let existing = try await read()
        guard let current = existing.first(where: { $0.mac == reservation.mac }) else { return }
        guard current.ip == reservation.ip, let index = current.index,
              reservation.index == index else { throw CPEError.uncertain }
        try await FirmwareNodes(rpc: rpc).delete(root: String(Self.staticRoot.dropLast()), index: index)
        let remaining = try await read()
        guard !remaining.contains(where: { $0.mac == reservation.mac }) else {
            throw CPEError.uncertain
        }
    }

    private func validateAddressPool(_ ip: String) async throws {
        let reply = try await rpc.call("get_value_by_xmlnode", data: .strings([
            "enabled": Self.lanRoot + "DHCPServerEnable",
            "router": Self.lanRoot + "IPInterface.1.IPInterfaceIPAddress",
            "mask": Self.lanRoot + "IPInterface.1.IPInterfaceSubnetMask",
            "min": Self.lanRoot + "MinAddress",
            "max": Self.lanRoot + "MaxAddress"
        ]), publicAccess: false)
        guard let enabled = reply["enabled"].text, ["0", "1"].contains(enabled) else {
            throw CPEError.malformedResponse
        }
        guard enabled == "1" else { throw DHCPReservationError.dhcpDisabled }
        guard let router = reply["router"].text, let routerValue = DHCPReservation.ipv4Value(router),
              let mask = reply["mask"].text, let maskValue = DHCPReservation.ipv4Value(mask),
              let min = reply["min"].text, let minValue = DHCPReservation.ipv4Value(min),
              let max = reply["max"].text, let maxValue = DHCPReservation.ipv4Value(max),
              minValue <= maxValue, let value = DHCPReservation.ipv4Value(ip) else {
            throw CPEError.malformedResponse
        }
        let hostMask = ~maskValue
        guard maskValue != 0, hostMask > 1, hostMask & (hostMask &+ 1) == 0 else {
            throw CPEError.malformedResponse
        }
        let network = routerValue & maskValue
        let broadcast = network | hostMask
        guard routerValue != network, routerValue != broadcast,
              minValue & maskValue == network, maxValue & maskValue == network else {
            throw CPEError.malformedResponse
        }
        guard value != routerValue else { throw DHCPReservationError.routerAddress }
        guard value != network, value != broadcast else { throw DHCPReservationError.invalidIPAddress }
        guard (minValue...maxValue).contains(value) else {
            throw DHCPReservationError.outsideAddressPool(min: min, max: max)
        }
    }

    private static func checkWriteReply(_ reply: JSONValue) throws {
        guard case .object = reply else { throw CPEError.malformedResponse }
        guard reply["ERRORSTATUS"] == .null else { throw CPEError.rejected }
        if reply["success"] != .null,
           reply["success"] != .bool(true), reply["success"].text != "true" {
            throw CPEError.rejected
        }
        if let result = reply["result"].text, result != "0" { throw CPEError.rejected }
        // Some stock pages ignore an empty acknowledgement. The required read-back below
        // decides whether the requested binding actually exists; an empty reply cannot succeed alone.
    }
}

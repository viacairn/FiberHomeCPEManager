import Foundation

/// One WAN service instance discovered from the firmware's own `WANDevice` tree.
///
/// The stock pages address every WAN service by the same four indices, so a single value
/// can build the paths for port mapping, DDNS and the cellular-data switch.
public struct WANConnectionRef: Sendable, Equatable, Hashable, Identifiable {
    public enum Link: String, Sendable, Codable, Hashable {
        case ipoe = "WANIPConnection"
        case pppoe = "WANPPPConnection"
    }

    public let device: Int
    public let link: Link
    public let wanConnectionIndex: Int
    public let serviceIndex: Int
    public let name: String
    public let enabled: Bool

    public var id: String { "\(device)-\(wanConnectionIndex)-\(link.rawValue)-\(serviceIndex)" }

    public var root: String {
        "InternetGatewayDevice.WANDevice.\(device).WANConnectionDevice.\(wanConnectionIndex).\(link.rawValue).\(serviceIndex)."
    }

    /// The stock pages use these two roots *without* a trailing dot for add/read.
    public var portMappingRoot: String { root + "PortMapping" }
    public var ddnsRoot: String { root + "X_FH_DDNSConfiguration" }

    public var title: String {
        let medium = device == 1 ? "5G" : "以太网"
        let mode = link == .ipoe ? "IPoE" : "PPPoE"
        let name = name.isEmpty ? "WAN\(device)" : name
        return "\(medium) · \(mode) · \(name)"
    }

    public init(device: Int, link: Link, wanConnectionIndex: Int = 1, serviceIndex: Int = 1,
                name: String, enabled: Bool) {
        self.device = device
        self.link = link
        self.wanConnectionIndex = wanConnectionIndex
        self.serviceIndex = serviceIndex
        self.name = name
        self.enabled = enabled
    }
}

public enum WANDiscovery {
    /// The stock DDNS/port-forward pages offer routed INTERNET services from this tree.
    public static func connections(_ rpc: any DeviceRPC) async throws -> [WANConnectionRef] {
        try await services(rpc).filter { $0.name.contains("INTERNET") && $0.name.contains("_R_") }
    }

    /// Enumerate the actual connection and service indices. Other services still matter
    /// for the stock port-forward page's WAN-device-wide external-port conflict check.
    static func services(_ rpc: any DeviceRPC) async throws -> [WANConnectionRef] {
        let serviceFields = JSONValue.strings(["Name": "Name", "Enable": "Enable"])
        let rows = try await FirmwareNodes(rpc: rpc).child(.object([
            "url": .string("WANDevice."), "num": .number(2),
            "node": .object([
                "wanenable": .string("X_FH_WANENABLE"),
                "wanconnection": .object([
                    "url": .string("WANConnectionDevice."),
                    "node": .object([
                        "ipoe": .object(["url": .string("WANIPConnection."), "node": serviceFields]),
                        "pppoe": .object(["url": .string("WANPPPConnection."), "node": serviceFields])
                    ])
                ])
            ])
        ]))
        var found: [WANConnectionRef] = []
        var devices = Set<Int>()
        for deviceRow in rows {
            guard let device = deviceRow["child_node_idx"].nodeIndex, devices.insert(device).inserted,
                  case .array(let connections) = deviceRow["wanconnection"] else {
                throw CPEError.malformedResponse
            }
            _ = try FirmwareNodes.flag(deviceRow["wanenable"])
            var connectionIndices = Set<Int>()
            for connectionRow in connections {
                guard let connection = connectionRow["child_node_idx"].nodeIndex,
                      connectionIndices.insert(connection).inserted else { throw CPEError.malformedResponse }
                for (alias, link) in [("ipoe", WANConnectionRef.Link.ipoe), ("pppoe", .pppoe)] {
                    guard case .array(let services) = connectionRow[alias] else { throw CPEError.malformedResponse }
                    var serviceIndices = Set<Int>()
                    for serviceRow in services {
                        guard let service = serviceRow["child_node_idx"].nodeIndex,
                              serviceIndices.insert(service).inserted,
                              case .string(let name) = serviceRow["Name"] else {
                            throw CPEError.malformedResponse
                        }
                        let enabled = try FirmwareNodes.flag(serviceRow["Enable"])
                        found.append(WANConnectionRef(device: device, link: link,
                                                      wanConnectionIndex: connection, serviceIndex: service,
                                                      name: name, enabled: enabled))
                    }
                }
            }
        }
        return found
    }

    public static func cellular(_ rpc: any DeviceRPC) async throws -> WANConnectionRef? {
        let all = try await connections(rpc)
        return all.first { $0.device == 1 && $0.link == .ipoe }
    }
}

extension JSONValue {
    /// `child_node_idx` is a string on this firmware but tolerate a JSON number.
    var nodeIndex: Int? {
        guard let text, !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let index = Int(text), index > 0 else { return nil }
        return index
    }
}

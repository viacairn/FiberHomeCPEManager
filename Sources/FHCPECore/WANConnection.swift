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

/// Thin, typed wrapper over the firmware node calls used by the new control pages.
/// Every write is checked before any read-back is attempted.
struct FirmwareNodes: Sendable {
    let rpc: any DeviceRPC

    func read(_ fields: [String: String]) async throws -> JSONValue {
        let reply = try await call("get_value_by_xmlnode", data: .strings(fields))
        guard case .object = reply else { throw CPEError.malformedResponse }
        return reply
    }

    func child(root: String, fields: [String: String]) async throws -> [JSONValue] {
        try await child(.object([
            "url": .string(root), "node": .strings(fields)
        ]))
    }

    func child(_ request: JSONValue) async throws -> [JSONValue] {
        let reply = try await call("get_xml_childnode_value", data: request)
        guard case .array(let rows) = reply["data"] else { throw CPEError.malformedResponse }
        return rows
    }

    func setSingle(_ path: String, _ value: String) async throws {
        let reply = try await call("set_single_by_xmlnode", data: .object([
            "url": .string(path), "value": .string(value)
        ]))
        try ensureWrite(reply)
    }

    func setMulti(_ pairs: [(path: String, value: String)]) async throws {
        var urls: [String: String] = [:], values: [String: String] = [:]
        for (index, pair) in pairs.enumerated() {
            urls["node\(index)"] = pair.path
            values["node\(index)"] = pair.value
        }
        let reply = try await call("set_value_by_xmlnode", data: .object([
            "url": .strings(urls), "value": .strings(values)
        ]))
        try ensureWrite(reply)
    }

    /// `add_xmlnode` answers with the new `child_node_idx` under the request's own key,
    /// e.g. `{"ddns":"3"}`.
    func add(root: String, key: String) async throws -> Int {
        let reply = try await call("add_xmlnode", data: .object([key: .string(root)]))
        // A positive instance index is this method's acknowledgement. Honour explicit
        // rejection flags as well, even when a contradictory index is present.
        try checkExplicitFailure(reply)
        guard let index = reply[key].nodeIndex else {
            throw CPEError.uncertain
        }
        return index
    }

    func delete(root: String, index: Int) async throws {
        guard index > 0 else { throw CPEError.malformedResponse }
        let reply = try await call("del_xmlnode", data: .object([
            "url": .string(root), "index": .number(Double(index))
        ]))
        try ensureWrite(reply)
    }

    func ensureWrite(_ reply: JSONValue) throws {
        try checkExplicitFailure(reply)
        guard reply["success"] == .bool(true) || ["true", "1"].contains(reply["success"].text)
                || reply["result"].text == "0" else { throw CPEError.uncertain }
    }

    private func checkExplicitFailure(_ reply: JSONValue) throws {
        guard case .object = reply else { throw CPEError.malformedResponse }
        if reply["ERRORSTATUS"] != .null {
            if ["401", "403", "418"].contains(reply["ERRORSTATUS"].text) { throw CPEError.authentication }
            throw CPEError.rejected
        }
        if reply["success"] != .null, reply["success"] != .bool(true),
           !["true", "1"].contains(reply["success"].text) { throw CPEError.rejected }
        if reply["result"] != .null, reply["result"].text != "0" { throw CPEError.rejected }
    }

    private func call(_ method: String, data: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        let reply = try await rpc.call(method, data: data, publicAccess: false)
        try Task.checkCancellation()
        if reply["ERRORSTATUS"] != .null { try checkExplicitFailure(reply) }
        return reply
    }

    static func flag(_ value: JSONValue) throws -> Bool {
        switch value.text {
        case "0": return false
        case "1": return true
        default: throw CPEError.malformedResponse
        }
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

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

    public var id: String { "\(device)-\(link.rawValue)-\(serviceIndex)" }

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
    /// Reads the four possible WAN service slots (5G/ethernet × IPoE/PPPoE, service 1).
    /// Reads are individual because the firmware drops a whole batch on an unknown node.
    public static func connections(_ rpc: any DeviceRPC) async -> [WANConnectionRef] {
        var found: [WANConnectionRef] = []
        for device in 1...2 {
            for link in [WANConnectionRef.Link.ipoe, .pppoe] {
                let root = "InternetGatewayDevice.WANDevice.\(device).WANConnectionDevice.1.\(link.rawValue).1."
                guard let reply = try? await rpc.call(
                    "get_value_by_xmlnode",
                    data: .strings(["name": root + "Name", "enable": root + "Enable"]),
                    publicAccess: false
                ), let name = reply["name"].text, !name.isEmpty else { continue }
                guard name.contains("INTERNET") && name.contains("_R_") else { continue }
                found.append(WANConnectionRef(device: device, link: link,
                                              name: name, enabled: reply["enable"].text == "1"))
            }
        }
        return found
    }

    public static func cellular(_ rpc: any DeviceRPC) async -> WANConnectionRef? {
        let all = await connections(rpc)
        return all.first { $0.device == 1 } ?? all.first
    }
}

/// Thin, typed wrapper over the firmware node calls used by the new control pages.
/// Every write is checked before any read-back is attempted.
struct FirmwareNodes: Sendable {
    let rpc: any DeviceRPC

    func read(_ fields: [String: String]) async throws -> JSONValue {
        try await rpc.call("get_value_by_xmlnode", data: .strings(fields), publicAccess: false)
    }

    func child(root: String, fields: [String: String]) async throws -> [JSONValue] {
        let reply = try await rpc.call("get_xml_childnode_value", data: .object([
            "url": .string(root), "node": .strings(fields)
        ]), publicAccess: false)
        guard case .array(let rows) = reply["data"] else { throw CPEError.malformedResponse }
        return rows
    }

    func setSingle(_ path: String, _ value: String) async throws {
        let reply = try await rpc.call("set_single_by_xmlnode", data: .object([
            "url": .string(path), "value": .string(value)
        ]), publicAccess: false)
        try ensureWrite(reply)
    }

    func setMulti(_ pairs: [(path: String, value: String)]) async throws {
        var urls: [String: String] = [:], values: [String: String] = [:]
        for (index, pair) in pairs.enumerated() {
            urls["node\(index)"] = pair.path
            values["node\(index)"] = pair.value
        }
        let reply = try await rpc.call("set_value_by_xmlnode", data: .object([
            "url": .strings(urls), "value": .strings(values)
        ]), publicAccess: false)
        try ensureWrite(reply)
    }

    /// `add_xmlnode` answers with the new `child_node_idx` under the request's own key,
    /// e.g. `{"ddns":"3"}`.
    func add(root: String, key: String) async throws -> Int {
        let reply = try await rpc.call("add_xmlnode",
                                       data: .object([key: .string(root)]),
                                       publicAccess: false)
        if reply["ERRORSTATUS"] != .null { throw CPEError.rejected }
        guard let index = reply[key].text.flatMap(Int.init), index > 0 else {
            throw CPEError.uncertain
        }
        return index
    }

    func delete(root: String, index: Int) async throws {
        let reply = try await rpc.call("del_xmlnode", data: .object([
            "url": .string(root), "index": .number(Double(index))
        ]), publicAccess: false)
        if reply["ERRORSTATUS"] != .null { throw CPEError.rejected }
        if let success = reply["success"].text, success != "true", success != "1" {
            throw CPEError.rejected
        }
        if let result = reply["result"].text, result != "0", !result.isEmpty {
            throw CPEError.rejected
        }
    }

    func ensureWrite(_ reply: JSONValue) throws {
        if reply["ERRORSTATUS"] != .null { throw CPEError.rejected }
        if let success = reply["success"].text, success != "true", success != "1" {
            throw CPEError.rejected
        }
        if let result = reply["result"].text, result != "0", !result.isEmpty {
            throw CPEError.rejected
        }
    }
}

extension JSONValue {
    /// `child_node_idx` is a string on this firmware but tolerate a JSON number.
    var nodeIndex: Int? { text.flatMap(Int.init) }
}

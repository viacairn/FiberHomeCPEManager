import Foundation

public extension Notification.Name {
    static let firmwareRowsSkipped = Notification.Name("FHCPECore.firmwareRowsSkipped")
}

/// Thin, typed wrapper over the firmware node calls used by the new control pages.
/// Every write is checked before any read-back is attempted.
struct FirmwareNodes: Sendable {
    let rpc: any DeviceRPC

    static func reportSkippedRows(_ count: Int, table: String) {
        guard count > 0 else { return }
        NotificationCenter.default.post(name: .firmwareRowsSkipped, object: nil,
            userInfo: ["message": "\(table)有 \(count) 条记录无法解析，已跳过并显示其余记录。"])
    }

    func read(_ fields: [String: String]) async throws -> JSONValue {
        guard !fields.isEmpty else { return .object([:]) }
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
        try await write("set_single_by_xmlnode", data: .object([
            "url": .string(path), "value": .string(value)
        ]))
    }

    func setMulti(_ pairs: [(path: String, value: String)]) async throws {
        var urls: [String: String] = [:], values: [String: String] = [:]
        for (index, pair) in pairs.enumerated() {
            urls["node\(index)"] = pair.path
            values["node\(index)"] = pair.value
        }
        try await setMulti(urls: urls, values: values)
    }

    /// Keeps the stock page aliases for contracts that name fields explicitly.
    func setMulti(urls: [String: String], values: [String: String]) async throws {
        try await write("set_value_by_xmlnode", data: .object([
            "url": .strings(urls), "value": .strings(values)
        ]))
    }

    func write(_ method: String, data: JSONValue) async throws {
        let reply = try await call(method, data: data)
        try Self.checkWriteReply(reply)
    }

    /// `add_xmlnode` answers with the new `child_node_idx` under the request's own key,
    /// e.g. `{"ddns":"3"}`.
    func add(root: String, key: String) async throws -> Int {
        let reply = try await call("add_xmlnode", data: .object([key: .string(root)]))
        // A positive instance index is this method's acknowledgement. Honour explicit
        // rejection flags as well, even when a contradictory index is present.
        try Self.checkExplicitFailure(reply)
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
        try Self.checkWriteReply(reply)
    }

    static func checkWriteReply(_ reply: JSONValue) throws {
        try checkExplicitFailure(reply)
        guard reply["success"] == .bool(true) || ["true", "1"].contains(reply["success"].text)
                || reply["result"].text == "0" else { throw CPEError.uncertain }
    }

    private static func checkExplicitFailure(_ reply: JSONValue) throws {
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
        if reply["ERRORSTATUS"] != .null { try Self.checkExplicitFailure(reply) }
        return reply
    }

    static func bool(_ enabled: Bool) -> String { enabled ? "1" : "0" }

    static func flag(_ value: JSONValue) throws -> Bool {
        switch value.text {
        case "0": return false
        case "1": return true
        default: throw CPEError.malformedResponse
        }
    }
}


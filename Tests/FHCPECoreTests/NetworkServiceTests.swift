import Foundation
import Testing
@testable import FHCPECore

/// In-memory stand-in for the firmware node API. Flat values and child-table cells live in
/// one dictionary, so `get_xml_childnode_value` can group them by index exactly like the
/// device does.
private actor NetworkNodeRPC: DeviceRPC {
    var values: [String: String]
    private(set) var writes: [(method: String, path: String, value: String)] = []
    private var nextIndex: [String: Int] = [:]

    init(values: [String: String]) { self.values = values }

    func call(_ method: String, data: JSONValue, publicAccess: Bool) async throws -> JSONValue {
        switch method {
        case "get_value_by_xmlnode":
            var reply: [String: JSONValue] = [:]
            if case .object(let fields) = data {
                for (alias, path) in fields {
                    reply[alias] = values[path.text ?? ""].map(JSONValue.string) ?? .null
                }
            }
            return .object(reply)

        case "get_xml_childnode_value":
            if data["url"].text == "WANDevice." {
                let devices = (1...2).compactMap { device -> JSONValue? in
                    var links: [String: JSONValue] = [:]
                    var hasService = false
                    for (alias, link) in [("ipoe", "WANIPConnection"), ("pppoe", "WANPPPConnection")] {
                        let path = "InternetGatewayDevice.WANDevice.\(device).WANConnectionDevice.1.\(link).1."
                        if let name = values[path + "Name"], let enable = values[path + "Enable"] {
                            hasService = true
                            links[alias] = .array([.object([
                                "child_node_idx": .number(1), "Name": .string(name), "Enable": .string(enable)
                            ])])
                        } else { links[alias] = .array([]) }
                    }
                    guard hasService else { return nil }
                    links["child_node_idx"] = .number(1)
                    return .object([
                        "child_node_idx": .number(Double(device)), "wanenable": .string(device == 1 ? "1" : "0"),
                        "wanconnection": .array([.object(links)])
                    ])
                }
                return .object(["data": .array(devices)])
            }
            let root = (data["url"].text ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            var fields: [String: String] = [:]
            if case .object(let node) = data["node"] {
                for (alias, field) in node { fields[alias] = field.text ?? "" }
            }
            var rows: [String: [String: JSONValue]] = [:]
            let prefix = root + "."
            for (key, value) in values where key.hasPrefix(prefix) {
                let rest = String(key.dropFirst(prefix.count))
                let parts = rest.split(separator: ".", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                for (alias, field) in fields where field == parts[1] {
                    rows[parts[0], default: [:]][alias] = .string(value)
                }
            }
            let ordered = rows.keys.compactMap(Int.init).sorted().compactMap { index -> JSONValue? in
                guard var row = rows[String(index)] else { return nil }
                row["child_node_idx"] = .string(String(index))
                return .object(row)
            }
            return .object(["data": .array(ordered)])

        case "set_single_by_xmlnode":
            let path = data["url"].text ?? "", value = data["value"].text ?? ""
            values[path] = value
            writes.append((method, path, value))
            return .object(["success": .string("true")])

        case "set_value_by_xmlnode":
            if case .object(let urls) = data["url"], case .object(let vals) = data["value"] {
                for (alias, path) in urls {
                    guard let value = vals[alias]?.text, let key = path.text else { continue }
                    values[key] = value
                    writes.append((method, key, value))
                }
            }
            return .object(["success": .string("true")])

        case "add_xmlnode":
            guard case .object(let request) = data, let (key, rootValue) = request.first,
                  let root = rootValue.text else { throw CPEError.malformedResponse }
            let prefix = root + "."
            let current = values.keys.filter { $0.hasPrefix(prefix) }.compactMap { key -> Int? in
                let rest = key.dropFirst(prefix.count)
                return rest.split(separator: ".").first.flatMap { Int($0) }
            }.max() ?? 0
            let index = max(current, nextIndex[root] ?? 0) + 1
            nextIndex[root] = index
            return .object([key: .string(String(index))])

        case "del_xmlnode":
            let root = data["url"].text ?? "", index = data["index"].text ?? ""
            let prefix = root + "." + index + "."
            for key in values.keys where key.hasPrefix(prefix) { values.removeValue(forKey: key) }
            return .object(["success": .string("true")])

        default:
            throw CPEError.malformedResponse
        }
    }

    func set(_ path: String, _ value: String) { values[path] = value }
    func value(_ path: String) -> String? { values[path] }
}

private func cellularWANValues(device: Int = 1) -> [String: String] {
    let root = "InternetGatewayDevice.WANDevice.\(device).WANConnectionDevice.1.WANIPConnection.1."
    return [
        root + "Name": "1_INTERNET_R_VID_",
        root + "Enable": "1",
        "LANDevice.1.LANHostConfigManagement.IPInterface.1.IPInterfaceIPAddress": "192.168.8.1",
        "LANDevice.1.LANHostConfigManagement.IPInterface.1.IPInterfaceSubnetMask": "255.255.255.0"
    ]
}

@Suite struct NetworkServiceTests {
@Test func wanDiscoveryFindsCellularService() async throws {
    let rpc = NetworkNodeRPC(values: cellularWANValues())
    let wans = try await WANDiscovery.connections(rpc)
    #expect(wans.count == 1)
    #expect(wans.first?.device == 1)
    #expect(wans.first?.link == .ipoe)
    #expect(wans.first?.portMappingRoot.hasSuffix("WANIPConnection.1.PortMapping") == true)
}

@Test func mobileNetworkReadsAndWritesSwitches() async throws {
    var values = cellularWANValues()
    values[MobileNetworkService.airplaneNode] = "0"
    values[MobileNetworkService.antennaSwitchNode] = "1"
    values[MobileNetworkService.antennaTypeNode] = "2"
    values["X_FH_MobileNetwork.NetworkSettings.CarrierLockEnable"] = "0"
    let rpc = NetworkNodeRPC(values: values)
    let service = MobileNetworkService(rpc: rpc)

    let state = try await service.read()
    #expect(!state.airplaneMode)
    #expect(state.cellularDataEnabled)
    #expect(state.antennaEnabled)
    #expect(state.antennaType == .n78n77)

    let airplane = try await service.setAirplaneMode(true)
    #expect(airplane.airplaneMode)
    _ = try await service.setAirplaneMode(false)
    let data = try await service.setCellularData(false)
    #expect(!data.cellularDataEnabled)
    let antenna = try await service.setAntenna(enabled: true, type: .n41)
    #expect(antenna.antennaType == .n41)
    #expect(await rpc.value(MobileNetworkService.antennaTypeNode) == "1")
}

@Test func ddnsAddUpdateToggleAndDelete() async throws {
    let rpc = NetworkNodeRPC(values: cellularWANValues())
    let service = DDNSService(rpc: rpc)
    let wan = try #require(try await WANDiscovery.connections(rpc).first)

    var input = DDNSInput(wan: wan, provider: "dyndns", hostname: "home.example.com",
                          username: "admin", password: "secret", enabled: true)
    #expect(input.validationError == nil)
    let added = try await service.add(input)
    #expect(added.index == 1)
    #expect(added.hostname == "home.example.com")
    #expect(added.enabled)

    input.hostname = "new.example.com"
    input.enabled = false
    let updated = try await service.update(added, with: input)
    #expect(updated.hostname == "new.example.com")
    #expect(!updated.enabled)

    let enabled = try await service.setEnabled(updated, true)
    #expect(enabled.enabled)

    try await service.delete(enabled)
    #expect(try await service.read().isEmpty)
}

@Test func ddnsRejectsIncompleteInputBeforeWriting() async throws {
    let rpc = NetworkNodeRPC(values: cellularWANValues())
    let wan = try #require(try await WANDiscovery.connections(rpc).first)
    let input = DDNSInput(wan: wan, provider: "dyndns", hostname: "", username: "u", password: "p", enabled: true)
    #expect(input.validationError != nil)
    await #expect(throws: Error.self) { try await DDNSService(rpc: rpc).add(input) }
}

@Test func portMappingAddToggleAndDelete() async throws {
    let rpc = NetworkNodeRPC(values: cellularWANValues())
    let service = PortMappingService(rpc: rpc)
    let wan = try #require(try await WANDiscovery.connections(rpc).first)

    let input = PortMappingInput(wan: wan, localIP: "192.168.8.120",
                                 internalPort: 8080, internalEnd: 8080,
                                 externalPort: 18080, externalEnd: 18080,
                                 proto: .tcp, enabled: true)
    #expect(input.validationError == nil)
    let added = try await service.add(input)
    #expect(added.index == 1)
    #expect(added.localIP == "192.168.8.120")
    #expect(added.internalRange == "8080")

    let disabled = try await service.setEnabled(added, false)
    #expect(!disabled.enabled)

    try await service.delete(disabled)
    #expect(try await service.read().isEmpty)
}

@Test func portMappingValidationRejectsBadAddressAndRange() {
    let wan = WANConnectionRef(device: 1, link: .ipoe, name: "1_INTERNET_R_VID_", enabled: true)
    #expect(PortMappingInput(wan: wan, localIP: "999.1.1.1", internalPort: 80, internalEnd: 80,
                             externalPort: 80, externalEnd: 80, proto: .tcp, enabled: true).validationError != nil)
    #expect(PortMappingInput(wan: wan, localIP: "192.168.8.20", internalPort: 90, internalEnd: 80,
                             externalPort: 80, externalEnd: 80, proto: .tcp, enabled: true).validationError != nil)
    #expect(PortMappingInput(wan: wan, localIP: "192.168.8.20", internalPort: 0, internalEnd: 0,
                             externalPort: 80, externalEnd: 80, proto: .tcp, enabled: true).validationError != nil)
}

}

import Foundation
import Testing
@testable import FHCPECore

/// Replays RPC boundary replies without simulating service parsing or validation.
private actor AdvancedRPC: DeviceRPC {
    enum Reply: Sendable {
        case value(JSONValue)
        case authentication
        case offline
        case cancelled
        case cancelCaller(JSONValue)
    }
    struct Step: Sendable {
        let method: String
        let reply: Reply
        init(_ method: String, _ value: JSONValue) { self.method = method; self.reply = .value(value) }
        init(_ method: String, reply: Reply) { self.method = method; self.reply = reply }
    }
    struct Request: Sendable {
        let method: String
        let data: JSONValue
        let publicAccess: Bool
    }
    private var steps: [Step]
    private(set) var requests: [Request] = []
    init(_ steps: [Step]) { self.steps = steps }

    func call(_ method: String, data: JSONValue, publicAccess: Bool) async throws -> JSONValue {
        requests.append(Request(method: method, data: data, publicAccess: publicAccess))
        guard !steps.isEmpty else {
            Issue.record("Unexpected extra RPC: \(method)")
            throw CPEError.malformedResponse
        }
        let next = steps.removeFirst()
        guard next.method == method else {
            Issue.record("Expected RPC \(next.method), received \(method)")
            throw CPEError.malformedResponse
        }
        switch next.reply {
        case .value(let value): return value
        case .authentication: throw CPEError.authentication
        case .offline: throw URLError(.notConnectedToInternet)
        case .cancelled: throw CancellationError()
        case .cancelCaller(let value):
            withUnsafeCurrentTask { $0?.cancel() }
            return value
        }
    }
}

private let advancedWAN = WANConnectionRef(device: 1, link: .ipoe, name: "1_INTERNET_R_VID_", enabled: true)
private let acknowledged = JSONValue.object(["success": .bool(true)])
private let validLAN = JSONValue.strings(["router": "192.168.8.1", "mask": "255.255.255.0"])

private func discoveryTree(device: Int = 1, connection: Int = 1, service: Int = 1,
                           enabled: JSONValue = .string("1"), link: String = "ipoe") -> JSONValue {
    let serviceRow = JSONValue.object([
        "child_node_idx": .number(Double(service)), "Name": .string("1_INTERNET_R_VID_"), "Enable": enabled
    ])
    return .object(["data": .array([.object([
        "child_node_idx": .number(Double(device)), "wanenable": .string(device == 1 ? "1" : "0"),
        "wanconnection": .array([.object([
            "child_node_idx": .number(Double(connection)),
            "ipoe": .array(link == "ipoe" ? [serviceRow] : []),
            "pppoe": .array(link == "pppoe" ? [serviceRow] : [])
        ])])
    ])])])
}

private func discoverySteps(enabled: String = "1") -> [AdvancedRPC.Step] {
    [.init("get_xml_childnode_value", discoveryTree(enabled: .string(enabled)))]
}

private func ddnsRow(_ changes: [String: JSONValue] = [:]) -> JSONValue {
    var row: [String: JSONValue] = [
        "child_node_idx": .string("3"), "enabled": .string("1"),
        "provider": .string("dyndns"), "host": .string("router.example.invalid"),
        "user": .string("fixture-user"), "password": .string("fixture-password")
    ]
    row.merge(changes) { _, replacement in replacement }
    return .object(row)
}

private func mappingRow(_ changes: [String: JSONValue] = [:]) -> JSONValue {
    var row: [String: JSONValue] = [
        "child_node_idx": .string("3"), "enabled": .string("1"),
        "localIP": .string("192.168.8.120"), "internalPort": .string("8080"),
        "internalEnd": .string("8080"), "protocol": .string("TCP"),
        "externalPort": .string("18080"), "externalEnd": .string("18080")
    ]
    row.merge(changes) { _, replacement in replacement }
    return .object(row)
}

@Suite struct AdvancedNetworkSafetyTests {
    @Test func discoveryPropagatesAuthentication() async throws {
        let rpc = AdvancedRPC([.init("get_xml_childnode_value", reply: .authentication)])
        await #expect(throws: CPEError.authentication) { _ = try await WANDiscovery.connections(rpc) }
        #expect(await rpc.requests.count == 1)
    }

    @Test func discoveryPropagatesNetworkOutage() async {
        let rpc = AdvancedRPC([.init("get_xml_childnode_value", reply: .offline)])
        await #expect(throws: URLError.self) { _ = try await WANDiscovery.connections(rpc) }
        #expect(await rpc.requests.count == 1)
    }

    @Test func discoveryPropagatesCancellation() async {
        let rpc = AdvancedRPC([.init("get_xml_childnode_value", reply: .cancelled)])
        await #expect(throws: CancellationError.self) { _ = try await WANDiscovery.connections(rpc) }
        #expect(await rpc.requests.count == 1)
    }

    @Test func discoveryRejectsUnknownEnable() async {
        let rpc = AdvancedRPC([.init("get_xml_childnode_value", discoveryTree(enabled: .null))])
        await #expect(throws: CPEError.malformedResponse) { _ = try await WANDiscovery.connections(rpc) }
    }

    @Test func cellularDiscoveryDoesNotUseEthernetFallback() async throws {
        let rpc = AdvancedRPC([.init("get_xml_childnode_value", discoveryTree(device: 2))])
        #expect(try await WANDiscovery.cellular(rpc) == nil)
    }

    @Test func discoveryUsesFirmwareConnectionAndServiceIndices() async throws {
        let rpc = AdvancedRPC([.init("get_xml_childnode_value", discoveryTree(connection: 3, service: 7))])
        let found = try await WANDiscovery.connections(rpc)
        #expect(found.count == 1)
        #expect(found.first?.root == "InternetGatewayDevice.WANDevice.1.WANConnectionDevice.3.WANIPConnection.7.")
    }

    @Test func mobileReadRejectsMissingAirplaneStatus() async {
        let rpc = AdvancedRPC([
            .init("get_value_by_xmlnode", .strings(["antenna": "1", "antennaType": "2"]))
        ] + discoverySteps() + [.init("get_value_by_xmlnode", .strings(["enable": "1"]))])
        await #expect(throws: CPEError.malformedResponse) { _ = try await MobileNetworkService(rpc: rpc).read() }
    }

    @Test func emptyWriteReceiptCannotSucceedOrReadBack() async {
        let rpc = AdvancedRPC([.init("set_single_by_xmlnode", .object([:]))])
        await #expect(throws: CPEError.uncertain) { _ = try await MobileNetworkService(rpc: rpc).setAirplaneMode(false) }
        #expect(await rpc.requests.count == 1)
    }

    @Test func booleanRejectionStopsBeforeReadBack() async {
        let rpc = AdvancedRPC([.init("set_single_by_xmlnode", .object(["success": .bool(false)]))])
        await #expect(throws: CPEError.rejected) { _ = try await MobileNetworkService(rpc: rpc).setAirplaneMode(false) }
        #expect(await rpc.requests.count == 1)
    }

    @Test func cancellationAfterAcknowledgedWriteStopsWithoutAnotherRPC() async {
        let rpc = AdvancedRPC([.init("set_single_by_xmlnode", reply: .cancelCaller(acknowledged))])
        let operation = Task { try await MobileNetworkService(rpc: rpc).setAirplaneMode(false) }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(await rpc.requests.count == 1)
    }

    @Test func cancelledOperationDoesNotStartAWrite() async {
        let rpc = AdvancedRPC([.init("set_single_by_xmlnode", acknowledged)])
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MobileNetworkService(rpc: rpc).setAirplaneMode(false)
        }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(await rpc.requests.isEmpty)
    }

    @Test func antennaDisablePreservesTypeWithoutSubmittingTypeField() async throws {
        let rpc = AdvancedRPC([
            .init("set_value_by_xmlnode", acknowledged),
            .init("get_value_by_xmlnode", .strings(["airplane": "0", "antenna": "0", "antennaType": "2", "carrier": "0"]))
        ] + discoverySteps() + [.init("get_value_by_xmlnode", .strings(["enable": "1"]))])
        let state = try await MobileNetworkService(rpc: rpc).setAntenna(enabled: false, type: .n41)
        #expect(!state.antennaEnabled)
        #expect(state.antennaType == .n78n77)
        let write = try #require(await rpc.requests.first)
        guard case .object(let paths) = write.data["url"] else { Issue.record("Expected multi-node write"); return }
        #expect(paths.values.compactMap(\.text) == ["X_FH_MobileNetwork.NetworkSettings.AntennaOutterSwitch"])
        #expect(await rpc.requests.filter { $0.method == "set_value_by_xmlnode" }.count == 1)
    }

    @Test func unmatchedMobileReadBackPollsWithoutRepeatingWrite() async {
        let read = [AdvancedRPC.Step("get_value_by_xmlnode", .strings([
            "airplane": "0", "antenna": "1", "antennaType": "2", "carrier": "0"
        ]))] + discoverySteps() + [.init("get_value_by_xmlnode", .strings(["enable": "1"]))]
        let rpc = AdvancedRPC([.init("set_single_by_xmlnode", acknowledged)] + Array(repeating: read, count: 5).flatMap { $0 })
        await #expect(throws: CPEError.uncertain) { _ = try await MobileNetworkService(rpc: rpc).setAirplaneMode(true) }
        #expect(await rpc.requests.filter { $0.method == "set_single_by_xmlnode" }.count == 1)
    }

    @Test(arguments: ["child_node_idx", "enabled", "user", "password"])
    func ddnsReadRejectsMissingFields(_ field: String) async {
        let rpc = AdvancedRPC(discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array([ddnsRow([field: .null])])]))
        ])
        await #expect(throws: CPEError.malformedResponse) { _ = try await DDNSService(rpc: rpc).read() }
    }

    @Test func ddnsReadRejectsDuplicateIndices() async {
        let rpc = AdvancedRPC(discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array([ddnsRow(), ddnsRow()])]))
        ])
        await #expect(throws: CPEError.malformedResponse) { _ = try await DDNSService(rpc: rpc).read() }
    }

    @Test func ddnsKnownEmptyFieldsRemainDistinctFromMissingFields() async throws {
        let rpc = AdvancedRPC(discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array([ddnsRow([
                "enabled": .string("0"), "provider": .string(""), "host": .string(""),
                "user": .string(""), "password": .string("")
            ])])]))
        ])
        let entries = try await DDNSService(rpc: rpc).read()
        #expect(entries.first?.index == 3)
        #expect(entries.first?.enabled == false)
        #expect(entries.first?.password == "")
    }

    @Test func ddnsUpdateRequiresEveryWrittenFieldToMatch() async {
        let entry = DDNSEntry(wan: advancedWAN, index: 3, provider: "dyndns", hostname: "router.example.invalid",
                              username: "fixture-user", password: "fixture-password", enabled: true)
        let input = DDNSInput(wan: advancedWAN, provider: "No-IP.com", hostname: "router.example.invalid",
                              username: "changed-user", password: "changed-password", enabled: false)
        let rpc = AdvancedRPC([.init("set_value_by_xmlnode", acknowledged)] + discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array([ddnsRow()])]))
        ])
        await #expect(throws: CPEError.uncertain) { _ = try await DDNSService(rpc: rpc).update(entry, with: input) }
        #expect(await rpc.requests.filter { $0.method == "set_value_by_xmlnode" }.count == 1)
    }

    @Test func ddnsDeleteRequiresPositiveAcknowledgement() async {
        let entry = DDNSEntry(wan: advancedWAN, index: 3, provider: "dyndns", hostname: "router.example.invalid",
                              username: "fixture-user", password: "fixture-password", enabled: true)
        let rpc = AdvancedRPC([.init("del_xmlnode", .object([:]))] + discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array([])]))
        ])
        await #expect(throws: CPEError.uncertain) { try await DDNSService(rpc: rpc).delete(entry) }
        #expect(await rpc.requests.count == 1)
    }

    @Test(arguments: ["child_node_idx", "enabled", "internalEnd", "externalEnd", "protocol"])
    func mappingReadRejectsMissingFields(_ field: String) async {
        let rpc = AdvancedRPC(discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array([mappingRow([field: .null])])]))
        ])
        await #expect(throws: CPEError.malformedResponse) { _ = try await PortMappingService(rpc: rpc).read() }
    }

    @Test func mappingReadRejectsUnknownProtocol() async {
        let rpc = AdvancedRPC(discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array([mappingRow(["protocol": .string("SCTP")])])]))
        ])
        await #expect(throws: CPEError.malformedResponse) { _ = try await PortMappingService(rpc: rpc).read() }
    }

    @Test func mappingAddRequiresAllPortsToMatchIndependentReadBack() async {
        let input = PortMappingInput(wan: advancedWAN, localIP: "192.168.8.120", internalPort: 8080,
                                     internalEnd: 8080, externalPort: 18081, externalEnd: 18081, proto: .tcp, enabled: true)
        let rpc = AdvancedRPC([.init("get_value_by_xmlnode", validLAN)] + discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array([])])),
            .init("add_xmlnode", .strings(["portMap": "3"])),
            .init("set_value_by_xmlnode", acknowledged)
        ] + discoverySteps() + [.init("get_xml_childnode_value", .object(["data": .array([mappingRow()])]))])
        await #expect(throws: CPEError.uncertain) { _ = try await PortMappingService(rpc: rpc).add(input) }
        #expect(await rpc.requests.filter { $0.method == "add_xmlnode" }.count == 1)
        #expect(await rpc.requests.filter { $0.method == "set_value_by_xmlnode" }.count == 1)
    }

    @Test(arguments: ["192.168.8.1", "192.168.9.20", "192.168.8.0", "192.168.8.255"])
    func mappingRejectsGatewayAndAddressesOutsideUsableLAN(_ address: String) async {
        let input = PortMappingInput(wan: advancedWAN, localIP: address, internalPort: 8080,
                                     internalEnd: 8080, externalPort: 18080, externalEnd: 18080, proto: .tcp, enabled: false)
        let rpc = AdvancedRPC([.init("get_value_by_xmlnode", validLAN)])
        await #expect(throws: CPEError.unsupported("映射目标必须是当前 LAN 子网内的主机地址，且不能使用路由器地址。")) {
            _ = try await PortMappingService(rpc: rpc).add(input)
        }
        #expect(await rpc.requests.count == 1)
    }

    @Test(arguments: [(18070, 18080), (18090, 18100), (18070, 18100), (18081, 18082)])
    func mappingRejectsAllExternalRangeOverlapIncludingDisabledOtherProtocol(_ range: (Int, Int)) async {
        let input = PortMappingInput(wan: advancedWAN, localIP: "192.168.8.120", internalPort: 8080,
                                     internalEnd: 8080, externalPort: range.0, externalEnd: range.1, proto: .tcp, enabled: false)
        let rpc = AdvancedRPC([.init("get_value_by_xmlnode", validLAN)] + discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array([
                mappingRow(["externalEnd": .string("18090"), "protocol": .string("UDP"), "enabled": .string("0")])
            ])]))
        ])
        await #expect(throws: CPEError.unsupported("外部端口范围与此 WAN 上的现有映射重叠。")) {
            _ = try await PortMappingService(rpc: rpc).add(input)
        }
        #expect(await rpc.requests.allSatisfy { $0.method == "get_value_by_xmlnode" || $0.method == "get_xml_childnode_value" })
    }

    @Test func mappingOverlapIncludesOtherServicesOnSameWANDevice() async {
        let tree = JSONValue.object(["data": .array([.object([
            "child_node_idx": .number(1), "wanenable": .string("1"),
            "wanconnection": .array([.object([
                "child_node_idx": .number(1), "pppoe": .array([]),
                "ipoe": .array([
                    .object(["child_node_idx": .number(1), "Name": .string("1_INTERNET_R_VID_"), "Enable": .string("1")]),
                    .object(["child_node_idx": .number(2), "Name": .string("2_TR069_R_VID_"), "Enable": .string("1")])
                ])
            ])])
        ])])])
        let input = PortMappingInput(wan: advancedWAN, localIP: "192.168.8.120", internalPort: 8080,
                                     internalEnd: 8080, externalPort: 18080, externalEnd: 18080, proto: .tcp, enabled: false)
        let rpc = AdvancedRPC([
            .init("get_value_by_xmlnode", validLAN), .init("get_xml_childnode_value", tree),
            .init("get_xml_childnode_value", .object(["data": .array([])])),
            .init("get_xml_childnode_value", .object(["data": .array([mappingRow()])]))
        ])
        await #expect(throws: CPEError.unsupported("外部端口范围与此 WAN 上的现有映射重叠。")) {
            _ = try await PortMappingService(rpc: rpc).add(input)
        }
        #expect(await rpc.requests.count == 4)
    }

    @Test func cellularWriteIsBlockedWhileAirplaneModeIsOn() async {
        let rpc = AdvancedRPC([.init("get_value_by_xmlnode", .strings(["airplane": "1"]))])
        await #expect(throws: CPEError.unsupported("请先关闭飞行模式，再更改蜂窝数据。")) {
            _ = try await MobileNetworkService(rpc: rpc).setCellularData(true)
        }
        #expect(await rpc.requests.count == 1)
    }

    @Test func cellularWriteIsBlockedForRestrictedCarrier() async {
        let rpc = AdvancedRPC([
            .init("get_value_by_xmlnode", .strings(["airplane": "0", "carrier": "1"])),
            .init("get_value_by_xmlnode", .strings(["serials": "00101", "imsi": "999991234567890"]))
        ])
        await #expect(throws: CPEError.unsupported("当前 SIM 卡不符合运营商限制，无法更改蜂窝数据。")) {
            _ = try await MobileNetworkService(rpc: rpc).setCellularData(true)
        }
        #expect(await rpc.requests.count == 2)
    }

    @Test func cellularWriteRejectsUnknownCarrierLockState() async {
        let rpc = AdvancedRPC([.init("get_value_by_xmlnode", .strings(["airplane": "0"]))])
        await #expect(throws: CPEError.malformedResponse) {
            _ = try await MobileNetworkService(rpc: rpc).setCellularData(true)
        }
        #expect(await rpc.requests.count == 1)
    }

    @Test(arguments: [("001021234567890", false), ("999991234567890", true)])
    func mobileStateUsesAllowedCarrierPrefixes(_ value: (String, Bool)) async throws {
        let rpc = AdvancedRPC([
            .init("get_value_by_xmlnode", .strings(["airplane": "0", "antenna": "1", "antennaType": "2", "carrier": "1"])),
            .init("get_value_by_xmlnode", .strings(["serials": "00101,00102", "imsi": value.0]))
        ] + discoverySteps() + [.init("get_value_by_xmlnode", .strings(["enable": "1"]))])
        let state = try await MobileNetworkService(rpc: rpc).read()
        #expect(state.carrierRestricted == value.1)
        #expect(state.cellularBlocked == value.1)
    }

    @Test func mappingLimitUsesStableWANIdentityWhenEnableStateChanges() async {
        let rows = (1...8).map { mappingRow(["child_node_idx": .string(String($0))]) }
        let input = PortMappingInput(wan: advancedWAN, localIP: "192.168.8.120", internalPort: 8080,
                                     internalEnd: 8080, externalPort: 28080, externalEnd: 28080, proto: .tcp, enabled: false)
        let rpc = AdvancedRPC([.init("get_value_by_xmlnode", validLAN)] + discoverySteps(enabled: "0") + [
            .init("get_xml_childnode_value", .object(["data": .array(rows)]))
        ])
        await #expect(throws: CPEError.unsupported("每个 WAN 最多可添加 8 条端口映射。")) {
            _ = try await PortMappingService(rpc: rpc).add(input)
        }
        #expect(await rpc.requests.count == 3)
    }

    @Test(arguments: ["provider", "hostname", "username", "password"])
    func ddnsInputRejectsFieldsLongerThanFirmwareLimit(_ field: String) {
        var input = DDNSInput(wan: advancedWAN, provider: "dyndns", hostname: "router.example.invalid",
                              username: "fixture-user", password: "fixture-password", enabled: false)
        let overlong = String(repeating: "x", count: 65)
        switch field {
        case "provider": input.provider = overlong
        case "hostname": input.hostname = overlong
        case "username": input.username = overlong
        default: input.password = overlong
        }
        #expect(input.validationError != nil)
    }

    @Test func ddnsPerWANLimitStopsBeforeAnyMutation() async {
        let rows = (1...4).map { ddnsRow(["child_node_idx": .string(String($0))]) }
        let input = DDNSInput(wan: advancedWAN, provider: "dyndns", hostname: "other.example.invalid",
                              username: "fixture-user", password: "fixture-password", enabled: false)
        let rpc = AdvancedRPC(discoverySteps() + [
            .init("get_xml_childnode_value", .object(["data": .array(rows)]))
        ])
        await #expect(throws: CPEError.unsupported("每个 WAN 最多可添加 4 条 DDNS 配置。")) {
            _ = try await DDNSService(rpc: rpc).add(input)
        }
        #expect(await rpc.requests.allSatisfy { $0.method == "get_value_by_xmlnode" || $0.method == "get_xml_childnode_value" })
    }
}

import Testing
import Foundation
@testable import FHCPECore

struct DHCPReservationTests {
    @Test func normalizesUnicastMACAndTrimsIPv4() throws {
        let reservation = try DHCPReservation(mac: " 02-aa-bb-cc-dd-ee \n", ip: " 192.168.8.120 ")
        #expect(reservation.mac == "02:AA:BB:CC:DD:EE")
        #expect(reservation.ip == "192.168.8.120")
    }

    @Test(arguments: ["", "192.168.8", "192.168.8.256", "192.168.8.-1", "192.168.8.01",
                      "192.168.8.2/24", "192.168. 8.2", "０.1.2.3", "0.0.0.0",
                      "127.0.0.1", "224.0.0.1", "255.255.255.255"])
    func rejectsInvalidOrNonUnicastIPv4(_ ip: String) {
        #expect(throws: DHCPReservationError.invalidIPAddress) {
            try DHCPReservation(mac: "02:AA:BB:CC:DD:EE", ip: ip)
        }
    }

    @Test(arguments: ["", "02:AA:BB:CC:DD", "02:AA:BB:CC:DD:EEE", "02:AA:BB:CC:DD:GG",
                      "02:AA-BB:CC:DD:EE", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF",
                      "01:00:5E:00:00:01"])
    func rejectsInvalidOrNonUnicastMAC(_ mac: String) {
        #expect(throws: DHCPReservationError.invalidMACAddress) {
            try DHCPReservation(mac: mac, ip: "192.168.8.120")
        }
    }

    @Test(arguments: ["10.0.0.7", "172.16.1.7", "192.168.8.120"])
    func acceptsUnicastAddressesWithoutGuessingTheRouterSubnet(_ ip: String) throws {
        #expect(try DHCPReservation(mac: "02:AA:BB:CC:DD:EE", ip: ip).ip == ip)
    }

    @Test func readsTheStockStaticDHCPTableAndPreservesInstanceIndices() async throws {
        let rpc = DHCPReservationRPC(replies: [table(index: "17", mac: "02:aa:bb:cc:dd:ee", ip: "192.168.8.120")])
        let reservations = try await DHCPReservationService(rpc: rpc).read()
        #expect(reservations.count == 1)
        #expect(reservations.first?.index == 17)
        #expect(reservations.first?.mac == "02:AA:BB:CC:DD:EE")
        let calls = await rpc.calls
        #expect(calls.count == 1)
        #expect(calls[0].method == "get_xml_childnode_value")
        #expect(calls[0].data == .object([
            "url": .string("LANDevice.1.LANHostConfigManagement.X_FH_StaticDhcp."),
            "node": .strings(["mac": "MACAddress", "ip": "IPAddress"])
        ]))
        #expect(calls[0].publicAccess == false)
    }

    @Test func addsAReservationUsingTheStockPayloadAndRefreshesOnce() async throws {
        let rpc = DHCPReservationRPC(replies: [table(), .strings(["success": "true"]),
                                              table(index: "9", ip: "192.168.8.120")])
        let refreshed = try await DHCPReservationService(rpc: rpc).reserve(mac: "02-aa-bb-cc-dd-ee", ip: "192.168.8.120")
        #expect(refreshed.first?.index == 9)
        #expect(refreshed.first?.ip == "192.168.8.120")
        let calls = await rpc.calls
        #expect(calls.map(\.method) == ["get_xml_childnode_value", "add_set_xmlnode", "get_xml_childnode_value"])
        #expect(calls[1].data == .object([
            "url": .string("LANDevice.1.LANHostConfigManagement.X_FH_StaticDhcp."),
            "setNode": .object([
                "url": .strings(["MAC": "MACAddress", "IP": "IPAddress"]),
                "value": .strings(["MAC": "02:AA:BB:CC:DD:EE", "IP": "192.168.8.120"])
            ])
        ]))
        #expect(calls.allSatisfy { !$0.publicAccess })
    }

    @Test func editsTheMatchingMACInsteadOfAddingADuplicate() async throws {
        let rpc = DHCPReservationRPC(replies: [table(index: "17", ip: "192.168.8.110"),
                                              .strings(["result": "0"]), table(index: "17", ip: "192.168.8.120")])
        _ = try await DHCPReservationService(rpc: rpc).reserve(mac: "02:AA:BB:CC:DD:EE", ip: "192.168.8.120")
        let calls = await rpc.calls
        #expect(calls.map(\.method) == ["get_xml_childnode_value", "set_value_by_xmlnode", "get_xml_childnode_value"])
        #expect(calls[1].data == .object([
            "url": .strings([
                "node0": "LANDevice.1.LANHostConfigManagement.X_FH_StaticDhcp.17.MACAddress",
                "node1": "LANDevice.1.LANHostConfigManagement.X_FH_StaticDhcp.17.IPAddress"
            ]),
            "value": .strings(["node0": "02:AA:BB:CC:DD:EE", "node1": "192.168.8.120"])
        ]))
    }

    @Test func matchingReservationDoesNotWriteAgain() async throws {
        let rpc = DHCPReservationRPC(replies: [table(index: "17", ip: "192.168.8.120")])
        _ = try await DHCPReservationService(rpc: rpc).reserve(mac: "02:AA:BB:CC:DD:EE", ip: "192.168.8.120")
        #expect(await rpc.calls.count == 1)
    }

    @Test(arguments: ["192.168.8.1", "192.168.9.120", "192.168.8.0", "192.168.8.255"])
    func delegatesAddressPoolAndGatewayDecisionsToFirmware(_ ip: String) async throws {
        let rpc = DHCPReservationRPC(replies: [table(), .strings(["success": "true"]), table(index: "9", ip: ip)])
        _ = try await DHCPReservationService(rpc: rpc).reserve(mac: "02:AA:BB:CC:DD:EE", ip: ip)
        #expect(await rpc.calls.map(\.method) == ["get_xml_childnode_value", "add_set_xmlnode", "get_xml_childnode_value"])
    }

    @Test func invalidInputNeverSendsAnRPC() async throws {
        let rpc = DHCPReservationRPC(replies: [])
        await #expect(throws: DHCPReservationError.invalidIPAddress) {
            try await DHCPReservationService(rpc: rpc).reserve(mac: "02:AA:BB:CC:DD:EE", ip: "192.168.8.999")
        }
        #expect(await rpc.calls.isEmpty)
    }

    @Test func acknowledgedWriteReturnsTheRefreshedTableWithoutComparingFields() async throws {
        let rpc = DHCPReservationRPC(replies: [table(), .strings(["success": "true"]), table()])
        let refreshed = try await DHCPReservationService(rpc: rpc).reserve(mac: "02:AA:BB:CC:DD:EE", ip: "192.168.8.120")
        #expect(refreshed.isEmpty)
        #expect(await rpc.calls.filter { $0.method == "add_set_xmlnode" }.count == 1)
        #expect(await rpc.calls.count == 3)
    }

    @Test func explicitWriteRejectionIsSurfacedWithoutRefresh() async throws {
        let rpc = DHCPReservationRPC(replies: [table(), .strings(["success": "false"])])
        await #expect(throws: CPEError.rejected) {
            try await DHCPReservationService(rpc: rpc).reserve(mac: "02:AA:BB:CC:DD:EE", ip: "192.168.8.120")
        }
        #expect(await rpc.calls.count == 2)
    }

    @Test func malformedTableCannotBeMistakenForNoReservations() async throws {
        let rpc = DHCPReservationRPC(replies: [.object([:])])
        await #expect(throws: CPEError.malformedResponse) {
            try await DHCPReservationService(rpc: rpc).read()
        }
    }

    @Test func unparseableInstanceIndexIsSkipped() async throws {
        let rpc = DHCPReservationRPC(replies: [table(index: "17.IPAddress", ip: "192.168.8.110")])
        #expect(try await DHCPReservationService(rpc: rpc).read().isEmpty)
    }

    @Test func removeUsesTheLoadedIndexAndRefreshesOnce() async throws {
        let rpc = DHCPReservationRPC(replies: [.strings(["success": "true"]), table()])
        let binding = try DHCPReservation(mac: "02:AA:BB:CC:DD:EE", ip: "192.168.8.120", index: 17)
        let refreshed = try await DHCPReservationService(rpc: rpc).remove(binding)
        #expect(refreshed.isEmpty)
        let calls = await rpc.calls
        #expect(calls.map(\.method) == ["del_xmlnode", "get_xml_childnode_value"])
        #expect(calls[0].data == .object([
            "url": .string("LANDevice.1.LANHostConfigManagement.X_FH_StaticDhcp"), "index": .number(17)
        ]))
    }

    @Test func removeWithoutAnInstanceIndexDoesNotCallTheRouter() async throws {
        let rpc = DHCPReservationRPC(replies: [])
        let binding = try DHCPReservation(mac: "02:AA:BB:CC:DD:EE", ip: "192.168.8.120")
        await #expect(throws: CPEError.malformedResponse) { try await DHCPReservationService(rpc: rpc).remove(binding) }
        #expect(await rpc.calls.isEmpty)
    }

    private func table(index: String? = nil, mac: String = "02:AA:BB:CC:DD:EE", ip: String = "") -> JSONValue {
        let rows: [JSONValue] = index.map { [.strings(["child_node_idx": $0, "mac": mac, "ip": ip])] } ?? []
        return .object(["data": .array(rows)])
    }


}

private actor DHCPReservationRPC: DeviceRPC {
    struct Call: Sendable {
        let method: String
        let data: JSONValue
        let publicAccess: Bool
    }
    var calls: [Call] = []
    private var replies: [JSONValue]

    init(replies: [JSONValue]) { self.replies = replies }

    func call(_ method: String, data: JSONValue, publicAccess: Bool) async throws -> JSONValue {
        calls.append(Call(method: method, data: data, publicAccess: publicAccess))
        guard !replies.isEmpty else { throw CPEError.malformedResponse }
        return replies.removeFirst()
    }
}

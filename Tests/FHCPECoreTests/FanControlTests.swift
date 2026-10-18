import Testing
@testable import FHCPECore

private actor FanContractRPC: DeviceRPC {
    let acknowledgement: JSONValue
    let readback: JSONValue
    private(set) var calls: [(String, JSONValue)] = []

    init(acknowledgement: JSONValue = .object(["success": .string("true")]), readback: JSONValue) {
        self.acknowledgement = acknowledgement
        self.readback = readback
    }

    func call(_ method: String, data: JSONValue, publicAccess: Bool) async throws -> JSONValue {
        calls.append((method, data))
        return method == "get_value_by_xmlnode" ? readback : acknowledgement
    }
}

struct FanControlTests {
    @Test(arguments: FanMode.allCases)
    func savesEachModeUsingTheStockPageEnvelopeAndReadsItBack(_ mode: FanMode) async throws {
        let rpc = FanContractRPC(readback: .strings(["mode": mode.rawValue]))
        #expect(try await SettingsService(rpc: rpc).setFanMode(mode))
        let calls = await rpc.calls
        #expect(calls.count == 2)
        #expect(calls.first?.0 == "set_value_by_xmlnode")
        #expect(calls.first?.1["url"]["mode"].text == SettingsService.fanNode)
        #expect(calls.first?.1["value"]["mode"].text == mode.rawValue)
        #expect(calls.last?.0 == "get_value_by_xmlnode")
        #expect(calls.last?.1["mode"].text == SettingsService.fanNode)
    }

    @Test func missingAcknowledgementCannotBeReportedAsSuccess() async {
        let rpc = FanContractRPC(acknowledgement: .object([:]), readback: .strings(["mode": "1"]))
        await #expect(throws: CPEError.uncertain) { try await SettingsService(rpc: rpc).setFanMode(.silent) }
        #expect(await rpc.calls.count == 1)
    }

    @Test func rejectedSaveDoesNotRunAnUnrelatedRead() async {
        let rpc = FanContractRPC(acknowledgement: .strings(["success": "false"]), readback: .strings(["mode": "1"]))
        await #expect(throws: CPEError.rejected) { try await SettingsService(rpc: rpc).setFanMode(.silent) }
        #expect(await rpc.calls.count == 1)
    }

    @Test func acceptedSaveWithDifferentReadbackIsUncertain() async {
        let rpc = FanContractRPC(readback: .strings(["mode": "0"]))
        await #expect(throws: CPEError.uncertain) { try await SettingsService(rpc: rpc).setFanMode(.performance) }
        #expect(await rpc.calls.count == 2)
    }

    @Test func acceptedSaveWithMissingModeIsUncertain() async {
        let rpc = FanContractRPC(readback: .object([:]))
        await #expect(throws: CPEError.uncertain) { try await SettingsService(rpc: rpc).setFanMode(.performance) }
    }
}

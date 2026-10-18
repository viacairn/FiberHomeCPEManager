import Foundation
import Testing
@testable import FHCPECore

private struct RadioLockCall: Sendable {
    var method: String
    var data: JSONValue
}

private actor RadioLockReadGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

/// A local model of the documented firmware boundary. It never contacts a device.
private actor RadioLockRPC: DeviceRPC {
    static let cellRoot = "X_FH_MobileNetwork.LockCellList."
    static let settingsRoot = "X_FH_MobileNetwork.NetworkSettings."
    var cellEnabled: Bool
    var bandEnabled: Bool
    var cells: [LockedCell]
    var lte = "3"
    var nr = "78"
    var calls: [RadioLockCall] = []
    var statesAfterWrites: [[Bool]] = []
    var rejectBandDisable = false
    var ignoreBandDisable = false
    var ignoreCellEnable = false
    var ignoreCandidateWrite = false
    var invalidSwitch = false
    var airplaneEnabled = false
    var carrierLockEnabled = false
    var carrierSerialNumbers = ""
    var imsi = "460001234567890"
    var modemModel = "RG620T-EG"
    var n79Enabled = false
    var emptyPCI = false
    let firstReadGate: RadioLockReadGate?
    private var readGateUsed = false

    init(cellEnabled: Bool = false, bandEnabled: Bool = false,
         cells: [LockedCell] = [LockedCell(index: 3, act: 2, arfcn: 634464, pci: 101)],
         firstReadGate: RadioLockReadGate? = nil) {
        self.cellEnabled = cellEnabled; self.bandEnabled = bandEnabled; self.cells = cells
        self.firstReadGate = firstReadGate
    }

    func configure(rejectBandDisable: Bool = false, ignoreBandDisable: Bool = false,
                   ignoreCellEnable: Bool = false, ignoreCandidateWrite: Bool = false,
                   invalidSwitch: Bool = false, airplaneEnabled: Bool = false,
                   carrierLockEnabled: Bool = false, carrierSerialNumbers: String = "",
                   modemModel: String = "RG620T-EG", n79Enabled: Bool = false, emptyPCI: Bool = false) {
        self.rejectBandDisable = rejectBandDisable; self.ignoreBandDisable = ignoreBandDisable
        self.ignoreCellEnable = ignoreCellEnable; self.ignoreCandidateWrite = ignoreCandidateWrite
        self.invalidSwitch = invalidSwitch
        self.airplaneEnabled = airplaneEnabled; self.carrierLockEnabled = carrierLockEnabled
        self.carrierSerialNumbers = carrierSerialNumbers; self.modemModel = modemModel
        self.n79Enabled = n79Enabled
        self.emptyPCI = emptyPCI
    }

    func call(_ method: String, data: JSONValue, publicAccess: Bool) async throws -> JSONValue {
        calls.append(RadioLockCall(method: method, data: data))
        switch method {
        case "get_value_by_xmlnode":
            if let firstReadGate, !readGateUsed {
                readGateUsed = true
                await firstReadGate.pause()
            }
            var response: [String: JSONValue] = [:]
            for (alias, value) in data.objectPairs {
                switch value.text {
                case Self.cellRoot + "LockEnable": response[alias] = .string(invalidSwitch ? "unknown" : (cellEnabled ? "1" : "0"))
                case Self.settingsRoot + "LockBandEnable": response[alias] = .string(bandEnabled ? "1" : "0")
                case Self.settingsRoot + "LTELockBAND": response[alias] = .string(lte)
                case Self.settingsRoot + "NRLockBAND": response[alias] = .string(nr)
                case Self.settingsRoot + "airplan_on": response[alias] = .string(airplaneEnabled ? "1" : "0")
                case Self.settingsRoot + "CarrierLockEnable": response[alias] = .string(carrierLockEnabled ? "1" : "0")
                case Self.settingsRoot + "CarrierSerialNum": response[alias] = .string(carrierSerialNumbers)
                case "X_FH_MobileNetwork.SIM.1.IMSI": response[alias] = .string(imsi)
                case "DeviceInfo.ModemModel": response[alias] = .string(modemModel)
                case "DeviceInfo.X_FH_N79_Enable": response[alias] = .string(n79Enabled ? "1" : "0")
                default: throw CPEError.malformedResponse
                }
            }
            return .object(response)
        case "get_xml_childnode_value":
            guard data["url"].text == Self.cellRoot + "LockCell." else { throw CPEError.malformedResponse }
            return .object(["data": .array(cells.map {
                .object(["child_node_idx": .number(Double($0.index)), "act": .string(String($0.act)),
                         "arfcn": .string(String($0.arfcn)), "pci": .string(emptyPCI ? "" : $0.pciWireValue)])
            })])
        case "set_value_by_xmlnode":
            if rejectBandDisable && data["value"]["enable"].text == "0" {
                return .object(["success": .string("false")])
            }
            for (alias, pathValue) in data["url"].objectPairs {
                let value = data["value"][alias].text ?? ""
                switch pathValue.text {
                case Self.cellRoot + "LockEnable":
                    if !(ignoreCellEnable && value == "1") { cellEnabled = value == "1" }
                case Self.settingsRoot + "LockBandEnable":
                    if !(ignoreBandDisable && value == "0") { bandEnabled = value == "1" }
                case Self.settingsRoot + "LTELockBAND": lte = value
                case Self.settingsRoot + "NRLockBAND": nr = value
                default:
                    guard let path = pathValue.text,
                          let item = cells.firstIndex(where: { path.hasPrefix(Self.cellRoot + "LockCell.\($0.index).") })
                    else { throw CPEError.malformedResponse }
                    if !ignoreCandidateWrite {
                        if path.hasSuffix(".act") { cells[item].act = Int(value) ?? -1 }
                        if path.hasSuffix(".arfcn") { cells[item].arfcn = Int(value) ?? -1 }
                        if path.hasSuffix(".pci") { cells[item].pci = value.isEmpty ? nil : (Int(value) ?? -1) }
                    }
                }
            }
        case "add_set_xmlnode":
            guard data["url"].text == Self.cellRoot + "LockCell." else { throw CPEError.malformedResponse }
            if !ignoreCandidateWrite {
                let value = data["setNode"]["value"]
                cells.append(LockedCell(index: (cells.map(\.index).max() ?? 0) + 1,
                                        act: Int(value["act"].text ?? "") ?? -1,
                                        arfcn: Int(value["arfcn"].text ?? "") ?? -1,
                                        pci: value["pci"] == .string("") ? nil : (Int(value["pci"].text ?? "") ?? -1)))
            }
        case "del_xmlnode":
            if !ignoreCandidateWrite { cells.removeAll { $0.index == Int(data["index"].text ?? "") } }
        default: throw CPEError.malformedResponse
        }
        statesAfterWrites.append([cellEnabled, bandEnabled])
        return .object(["success": .string("true")])
    }
}

struct RadioLockTests {
    @Test func theStockEmptyPCICandidateIsRetainedWhenRead() async throws {
        let rpc = RadioLockRPC(cellEnabled: true)
        await rpc.configure(emptyPCI: true)
        let state = try await RadioLockService(rpc: rpc).read()
        #expect(state.cells.count == 1)
        #expect(state.cells.first?.arfcn == 634464)
        #expect(state.cells.first?.pci == nil)
        #expect(state.cellLockEnabled)
        #expect(state.mode == .cell(rat: 2, arfcn: 634464, pci: nil))
    }

    @Test func anEmptyPCICandidateCannotPreventTurningBothLocksOff() async throws {
        let rpc = RadioLockRPC(cellEnabled: true, bandEnabled: true)
        await rpc.configure(emptyPCI: true)
        let state = try await RadioLockService(rpc: rpc).disableAll()
        #expect(!state.cellLockEnabled && !state.bandLockEnabled)
        #expect(state.cells.count == 1)
        #expect(state.mode == .automatic)
    }

    @Test func theLegacySnapshotParserRetainsAStockEmptyPCICandidate() {
        let cells = LG6851Adapter.parseLockedCells(.object(["data": .array([
            .object(["child_node_idx": .number(3), "act": .string("2"),
                     "arfcn": .string("634464"), "pci": .string("")])
        ])]))
        #expect(cells.count == 1)
        #expect(cells.first?.arfcn == 634464)
        #expect(cells.first?.pci == nil)
        #expect(LG6851Adapter.lockMode(cellEnable: "1", cells: cells, bandEnable: "0", lte: "", nr: "") ==
                .cell(rat: 2, arfcn: 634464, pci: nil))
    }

    @Test func frequencyOnlyCandidatesRoundTripEmptyPCIThroughAddEditAndDelete() async throws {
        let rpc = RadioLockRPC()
        let service = RadioLockService(rpc: rpc)
        let added = try await service.addCell(act: 1, arfcn: 1850, pci: nil)
        let candidate = try #require(added.cells.first { $0.arfcn == 1850 })
        #expect(candidate.pci == nil)
        let add = try #require(await rpc.calls.first { $0.method == "add_set_xmlnode" })
        #expect(add.data["setNode"]["value"]["pci"] == .string(""))
        let edited = try await service.updateCell(index: candidate.index, act: 2, arfcn: 504990, pci: nil)
        #expect(edited.cells.contains { $0.arfcn == 504990 && $0.pci == nil })
        let update = try #require(await rpc.calls.first { $0.method == "set_value_by_xmlnode" })
        #expect(update.data["value"]["pci"] == .string(""))
        let deleted = try await service.deleteCell(index: candidate.index)
        #expect(deleted.cells == [LockedCell(index: 3, act: 2, arfcn: 634464, pci: 101)])
    }

    @Test func frequencyOnlyCandidateDuplicatesAreRejectedWithoutTreatingThemAsPCIZero() async throws {
        let rpc = RadioLockRPC(cells: [LockedCell(index: 3, act: 2, arfcn: 634464, pci: nil)])
        let service = RadioLockService(rpc: rpc)
        await #expect(throws: Error.self) { try await service.addCell(act: 2, arfcn: 634464, pci: nil) }
        #expect(await rpc.statesAfterWrites.isEmpty)
        let state = try await service.addCell(act: 2, arfcn: 634464, pci: 0)
        #expect(state.cells.count == 2)
        #expect(state.cells.contains { $0.pci == nil })
        #expect(state.cells.contains { $0.pci == 0 })
    }

    @Test func legacyCellLockBackendWritesAnEmptyPCIWithoutInventingZero() async throws {
        let rpc = RecordingRPC()
        try await LG6851LockBackend(rpc: rpc).apply(.cell(rat: 2, arfcn: 634464, pci: nil))
        let add = try #require(rpc.calls.first { $0.method == "add_set_xmlnode" })
        #expect(add.data["setNode"]["value"]["pci"] == .string(""))
    }

    @Test func aPublicReadPreventsAConcurrentMutationFromMixingItsSnapshot() async throws {
        let gate = RadioLockReadGate()
        let rpc = RadioLockRPC(firstReadGate: gate)
        let service = RadioLockService(rpc: rpc)
        let reading = Task { try await service.read() }
        await gate.waitForEntry()
        await #expect(throws: CPEError.busy) { try await service.setCellLockEnabled(true) }
        await gate.release()
        let state = try await reading.value
        #expect(state.mode == .automatic)
        #expect(await rpc.statesAfterWrites.isEmpty)
    }

    @Test func aMutationPreventsAPublicReadFromExposingItsIntermediateState() async throws {
        let gate = RadioLockReadGate()
        let rpc = RadioLockRPC(firstReadGate: gate)
        let service = RadioLockService(rpc: rpc)
        let changing = Task { try await service.setCellLockEnabled(true) }
        await gate.waitForEntry()
        await #expect(throws: CPEError.busy) { try await service.read() }
        await gate.release()
        #expect(try await changing.value.cellLockEnabled)
    }

    @Test func readsCandidatesEvenWhenTheCellSwitchIsOff() async throws {
        let state = try await RadioLockService(rpc: RadioLockRPC()).read()
        #expect(state.cells == [LockedCell(index: 3, act: 2, arfcn: 634464, pci: 101)])
        #expect(state.mode == .automatic)
    }

    @Test func conflictCanBeRepairedToBothSwitchesOff() async throws {
        let rpc = RadioLockRPC(cellEnabled: true, bandEnabled: true)
        let service = RadioLockService(rpc: rpc)
        let before = try await service.read()
        #expect(before.hasConflict)
        #expect(before.mode == .unknown)
        let after = try await service.disableAll()
        #expect(after.mode == .automatic)
        #expect(!after.cellLockEnabled && !after.bandLockEnabled)
        #expect(after.cells.count == 1)
    }

    @Test func enablingCellLockTurnsBandsOffAndReadsBackBeforeEnabling() async throws {
        let rpc = RadioLockRPC(bandEnabled: true)
        let state = try await RadioLockService(rpc: rpc).setCellLockEnabled(true)
        #expect(state.cellLockEnabled && !state.bandLockEnabled)
        let calls = await rpc.calls
        let disable = try #require(calls.firstIndex { $0.data["value"]["enable"].text == "0" })
        let enable = try #require(calls.firstIndex { $0.data["value"]["Enable"].text == "1" })
        #expect(disable < enable)
        #expect(calls[(disable + 1)..<enable].contains { $0.method == "get_value_by_xmlnode" })
        #expect(await rpc.statesAfterWrites.allSatisfy { $0 != [true, true] })
        #expect(calls[enable].method == "set_value_by_xmlnode")
        #expect(calls[enable].data["url"]["Enable"].text == "X_FH_MobileNetwork.LockCellList.LockEnable")
    }

    @Test func rejectedBandDisableNeverEnablesCellLock() async {
        let rpc = RadioLockRPC(bandEnabled: true)
        await rpc.configure(rejectBandDisable: true)
        await #expect(throws: Error.self) { try await RadioLockService(rpc: rpc).setCellLockEnabled(true) }
        #expect(await rpc.calls.allSatisfy { $0.data["value"]["Enable"].text != "1" })
    }

    @Test func unconfirmedBandDisableNeverEnablesCellLock() async {
        let rpc = RadioLockRPC(bandEnabled: true)
        await rpc.configure(ignoreBandDisable: true)
        await #expect(throws: Error.self) { try await RadioLockService(rpc: rpc).setCellLockEnabled(true) }
        #expect(await rpc.calls.allSatisfy { $0.data["value"]["Enable"].text != "1" })
    }

    @Test func enablingCellLockRequiresAConfirmedCandidateAndSwitch() async {
        let empty = RadioLockRPC(cells: [])
        await #expect(throws: Error.self) { try await RadioLockService(rpc: empty).setCellLockEnabled(true) }
        #expect(await empty.statesAfterWrites.isEmpty)
        let ignored = RadioLockRPC()
        await ignored.configure(ignoreCellEnable: true)
        await #expect(throws: Error.self) { try await RadioLockService(rpc: ignored).setCellLockEnabled(true) }
    }

    @Test func bandWriteUsesOneThreeFieldRequestAndMergesB12B17() async throws {
        let rpc = RadioLockRPC(cellEnabled: true)
        await rpc.configure(modemModel: "RG620T-NA")
        let state = try await RadioLockService(rpc: rpc).setBandLockEnabled(true, lte: [17, 2, 2], nr: [78])
        #expect(state.mode == .bands(lte: [2, 12, 17], nr: [78]))
        let calls = await rpc.calls
        let disable = try #require(calls.firstIndex { $0.data["value"]["Enable"].text == "0" })
        let enable = try #require(calls.firstIndex { $0.data["value"]["enable"].text == "1" })
        #expect(calls[(disable + 1)..<enable].contains { $0.method == "get_value_by_xmlnode" })
        #expect(calls[enable].method == "set_value_by_xmlnode")
        #expect(calls[enable].data["url"].objectPairs.count == 3)
        #expect(calls[enable].data["value"] == .strings(["enable": "1", "band4": "2,12,17", "band5": "78"]))
        #expect(await rpc.statesAfterWrites.allSatisfy { $0 != [true, true] })
    }

    @Test func emptyBandsOrStandaloneB32AreRejectedBeforeAnyWrite() async {
        for lte in [[], [32]] {
            let rpc = RadioLockRPC()
            await #expect(throws: Error.self) { try await RadioLockService(rpc: rpc).setBandLockEnabled(true, lte: lte, nr: []) }
            #expect(await rpc.statesAfterWrites.isEmpty)
        }
    }

    @Test func addingAnLTECandidateUsesLowercaseFactoryListFields() async throws {
        let rpc = RadioLockRPC()
        let state = try await RadioLockService(rpc: rpc).addCell(act: 1, arfcn: 1850, pci: 108)
        #expect(state.cells.count == 2)
        let call = try #require(await rpc.calls.first { $0.method == "add_set_xmlnode" })
        #expect(call.data == .object([
            "url": .string("X_FH_MobileNetwork.LockCellList.LockCell."),
            "setNode": .object(["url": .strings(["act": "act", "arfcn": "arfcn", "pci": "pci"]),
                                "value": .strings(["act": "1", "arfcn": "1850", "pci": "108"])])
        ]))
        #expect(!state.cellLockEnabled)
    }

    @Test func duplicatesAndTheTwentyFirstCandidateAreRejectedWithoutWriting() async {
        let duplicate = RadioLockRPC()
        await #expect(throws: Error.self) { try await RadioLockService(rpc: duplicate).addCell(act: 1, arfcn: 634464, pci: 101) }
        #expect(await duplicate.statesAfterWrites.isEmpty)
        let full = RadioLockRPC(cells: (1...20).map { LockedCell(index: $0, act: 2, arfcn: 634464, pci: $0) })
        await #expect(throws: Error.self) { try await RadioLockService(rpc: full).addCell(act: 2, arfcn: 634464, pci: 21) }
        #expect(await full.statesAfterWrites.isEmpty)
    }

    @Test func candidateUpdatesAddressTheActualChildIndexAndVerifyReadback() async throws {
        let rpc = RadioLockRPC()
        let state = try await RadioLockService(rpc: rpc).updateCell(index: 3, act: 1, arfcn: 1850, pci: 108)
        #expect(state.cells == [LockedCell(index: 3, act: 1, arfcn: 1850, pci: 108)])
        let write = try #require(await rpc.calls.first { $0.method == "set_value_by_xmlnode" })
        #expect(write.data["url"]["act"].text == "X_FH_MobileNetwork.LockCellList.LockCell.3.act")
        #expect(write.data["url"]["arfcn"].text == "X_FH_MobileNetwork.LockCellList.LockCell.3.arfcn")
        #expect(write.data["url"]["pci"].text == "X_FH_MobileNetwork.LockCellList.LockCell.3.pci")
    }

    @Test func deletingLastActiveCandidateDisablesCellLockFirst() async throws {
        let rpc = RadioLockRPC(cellEnabled: true)
        let state = try await RadioLockService(rpc: rpc).deleteCell(index: 3)
        #expect(state.cells.isEmpty)
        #expect(!state.cellLockEnabled)
        let calls = await rpc.calls
        let disable = try #require(calls.firstIndex { $0.data["value"]["Enable"].text == "0" })
        let deletion = try #require(calls.firstIndex { $0.method == "del_xmlnode" })
        #expect(disable < deletion)
        #expect(calls[deletion].data == .object(["url": .string("X_FH_MobileNetwork.LockCellList.LockCell."), "index": .number(3)]))
    }

    @Test func acceptedCandidateWriteWithUnchangedReadbackIsAnError() async {
        let rpc = RadioLockRPC()
        await rpc.configure(ignoreCandidateWrite: true)
        await #expect(throws: Error.self) { try await RadioLockService(rpc: rpc).addCell(act: 2, arfcn: 504990, pci: 524) }
    }

    @Test func anUnknownSwitchCannotBeTreatedAsAutomatic() async {
        let rpc = RadioLockRPC()
        await rpc.configure(invalidSwitch: true)
        await #expect(throws: Error.self) { try await RadioLockService(rpc: rpc).setBandLockEnabled(true, lte: [3], nr: []) }
        #expect(await rpc.statesAfterWrites.isEmpty)
    }

    @Test func flightModeAndCarrierMismatchBlockEnablingAndCandidateEdits() async {
        let airplane = RadioLockRPC()
        await airplane.configure(airplaneEnabled: true)
        await #expect(throws: Error.self) { try await RadioLockService(rpc: airplane).setCellLockEnabled(true) }
        #expect(await airplane.statesAfterWrites.isEmpty)
        let carrier = RadioLockRPC()
        await carrier.configure(carrierLockEnabled: true, carrierSerialNumbers: "46003,46011")
        await #expect(throws: Error.self) { try await RadioLockService(rpc: carrier).addCell(act: 2, arfcn: 504990, pci: 524) }
        #expect(await carrier.statesAfterWrites.isEmpty)
    }

    @Test func carrierPrefixMatchAllowsConfigurationWithoutExposingIMSIInState() async throws {
        let rpc = RadioLockRPC()
        await rpc.configure(carrierLockEnabled: true, carrierSerialNumbers: ",46000,46003")
        let state = try await RadioLockService(rpc: rpc).setCellLockEnabled(true)
        #expect(!state.carrierRestricted)
        #expect(state.cellLockEnabled)
    }

    @Test func modemSpecificBandAndN79RulesRejectUnsupportedValues() async {
        let rpc = RadioLockRPC()
        await #expect(throws: Error.self) { try await RadioLockService(rpc: rpc).setBandLockEnabled(true, lte: [12], nr: []) }
        await #expect(throws: Error.self) { try await RadioLockService(rpc: rpc).setBandLockEnabled(true, lte: [], nr: [79]) }
        await #expect(throws: Error.self) { try await RadioLockService(rpc: rpc).addCell(act: 2, arfcn: 700000, pci: 10) }
        #expect(await rpc.statesAfterWrites.isEmpty)
    }

    /// The list renders `pciDisplay`, never the optional itself. A regression here shows
    /// up as "PCI Optional(285)" in the lock panel.
    @Test func optionalPCIDisplaysAsAnyAndWritesAnEmptyString() {
        let blank = LockedCell(index: 1, act: 2, arfcn: 634464, pci: nil)
        #expect(blank.pciDisplay == "任意")
        #expect(blank.pciWireValue == "")
        #expect(LockedCell(index: 2, act: 1, arfcn: 1850, pci: 0).pciDisplay == "0")
        #expect(LockedCell(index: 3, act: 2, arfcn: 504990, pci: 101).pciDisplay == "285")
    }
}

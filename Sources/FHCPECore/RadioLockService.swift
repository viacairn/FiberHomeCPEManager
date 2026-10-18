import Foundation

/// The two firmware switches and their retained configuration are deliberately separate.
/// Candidates remain useful while their switch is off; a dual-enabled device needs repair.
public struct RadioLockState: Sendable, Equatable {
    public var cellLockEnabled: Bool
    public var bandLockEnabled: Bool
    public var cells: [LockedCell]
    public var lteBands: [Int]
    public var nrBands: [Int]
    public var airplaneModeEnabled: Bool
    public var carrierRestricted: Bool
    public var supportedLTEBands: [Int]
    public var supportedNRBands: [Int]
    public var allowsN79ARFCN: Bool

    public init(cellLockEnabled: Bool = false, bandLockEnabled: Bool = false,
                cells: [LockedCell] = [], lteBands: [Int] = [], nrBands: [Int] = [],
                airplaneModeEnabled: Bool = false, carrierRestricted: Bool = false,
                supportedLTEBands: [Int] = [1, 3, 5, 7, 8, 20, 28, 32, 38, 40, 41, 42, 43],
                supportedNRBands: [Int] = [1, 3, 5, 7, 8, 20, 28, 38, 40, 41, 77, 78],
                allowsN79ARFCN: Bool = true) {
        self.cellLockEnabled = cellLockEnabled; self.bandLockEnabled = bandLockEnabled
        self.cells = cells; self.lteBands = lteBands; self.nrBands = nrBands
        self.airplaneModeEnabled = airplaneModeEnabled; self.carrierRestricted = carrierRestricted
        self.supportedLTEBands = supportedLTEBands; self.supportedNRBands = supportedNRBands
        self.allowsN79ARFCN = allowsN79ARFCN
    }

    public var hasConflict: Bool { cellLockEnabled && bandLockEnabled }
    public var mode: LockMode {
        if hasConflict { return .unknown }
        if cellLockEnabled {
            guard let first = cells.first else { return .unknown }
            return .cell(rat: first.act, arfcn: first.arfcn, pci: first.pci)
        }
        if bandLockEnabled { return .bands(lte: lteBands, nr: nrBands) }
        return .automatic
    }
    public var configurationBlockedReason: String? {
        if airplaneModeEnabled && carrierRestricted { return "请先关闭飞行模式，并使用运营商允许的 SIM 卡。" }
        if airplaneModeEnabled { return "飞行模式已开启，暂时无法配置锁定。" }
        if carrierRestricted { return "当前 SIM 卡不符合运营商限制，暂时无法配置锁定。" }
        return nil
    }
}

/// Uses the stock LG6851F cellLockSet/frequencyLockSet contracts. No device write is
/// retried: successful replies are followed by independent reads before returning.
public actor RadioLockService {
    private let rpc: any DeviceRPC
    private var busy = false
    private static let cellRoot = "X_FH_MobileNetwork.LockCellList."
    private static let listRoot = cellRoot + "LockCell."
    private static let settingsRoot = "X_FH_MobileNetwork.NetworkSettings."

    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    public func read() async throws -> RadioLockState {
        // Actor isolation alone does not cover the awaits inside the three-part read.
        // Hold the same gate as mutations so every returned state is one transaction.
        try beginOperation(); defer { busy = false }
        return try await readState()
    }

    public func setCellLockEnabled(_ enabled: Bool) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        var state = try await readState()
        if !enabled {
            if state.hasConflict { return try await turnOffBoth(state) }
            try await writeCellSwitch(false)
            let result = try await readState()
            guard !result.cellLockEnabled else { throw CPEError.uncertain }
            return result
        }
        try ensureAllowed(state)
        guard !state.cells.isEmpty else { throw CPEError.unsupported("请先添加至少一个锁定候选小区。") }
        if state.hasConflict { state = try await turnOffBoth(state) }
        // This read is the interlock: a rejected or unconfirmed OFF never reaches ON.
        try await writeBandConfiguration(enabled: false, lte: state.lteBands, nr: state.nrBands)
        let interlock = try await readState()
        guard !interlock.bandLockEnabled else { throw CPEError.uncertain }
        try ensureAllowed(interlock)
        guard !interlock.cells.isEmpty else { throw CPEError.uncertain }
        try Task.checkCancellation()
        try await writeCellSwitch(true)
        let result = try await readState()
        try await rejectConflict(result)
        guard result.cellLockEnabled && !result.bandLockEnabled else { throw CPEError.uncertain }
        return result
    }

    public func setBandLockEnabled(_ enabled: Bool, lte: [Int] = [], nr: [Int] = []) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        var state = try await readState()
        if !enabled {
            if state.hasConflict { return try await turnOffBoth(state) }
            try await writeBandConfiguration(enabled: false, lte: state.lteBands, nr: state.nrBands)
            let result = try await readState()
            guard !result.bandLockEnabled else { throw CPEError.uncertain }
            return result
        }
        try ensureAllowed(state)
        let bands = try normalizedBands(lte: lte, nr: nr, state: state)
        if state.hasConflict { state = try await turnOffBoth(state) }
        try await writeCellSwitch(false)
        let interlock = try await readState()
        guard !interlock.cellLockEnabled else { throw CPEError.uncertain }
        try ensureAllowed(interlock)
        _ = try normalizedBands(lte: bands.lte, nr: bands.nr, state: interlock)
        try Task.checkCancellation()
        try await writeBandConfiguration(enabled: true, lte: bands.lte, nr: bands.nr)
        let result = try await readState()
        try await rejectConflict(result)
        guard !result.cellLockEnabled && result.bandLockEnabled,
              result.lteBands == bands.lte, result.nrBands == bands.nr else { throw CPEError.uncertain }
        return result
    }

    /// Always available for conflict repair, including while a SIM or flight restriction
    /// prevents enabling a lock. Retained candidate/band choices are not erased.
    public func disableAll() async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        return try await turnOffBoth(readState())
    }

    public func addCell(act: Int, arfcn: Int, pci: Int?) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        let state = try await readState()
        try ensureCandidateEditingAllowed(state)
        try validateCell(act: act, arfcn: arfcn, pci: pci, state: state)
        guard state.cells.count < 20 else { throw CPEError.unsupported("最多可配置 20 个候选小区。") }
        guard !state.cells.contains(where: { $0.arfcn == arfcn && $0.pci == pci }) else {
            throw CPEError.unsupported("已存在相同频点和 PCI 的候选小区。")
        }
        let candidate = LockedCell(index: 0, act: act, arfcn: arfcn, pci: pci)
        let value = ["act": String(act), "arfcn": String(arfcn), "pci": candidate.pciWireValue]
        try Task.checkCancellation()
        try await write("add_set_xmlnode", data: .object([
            "url": .string(Self.listRoot),
            "setNode": .object(["url": .strings(["act": "act", "arfcn": "arfcn", "pci": "pci"]),
                                "value": .strings(value)])
        ]))
        let result = try await readState()
        let expected = state.cells + [candidate]
        try await verifyCandidates(result, expected: expected, switches: state)
        return result
    }

    public func updateCell(index: Int, act: Int, arfcn: Int, pci: Int?) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        let state = try await readState()
        try ensureCandidateEditingAllowed(state)
        try validateCell(act: act, arfcn: arfcn, pci: pci, state: state)
        guard state.cells.contains(where: { $0.index == index }) else { throw CPEError.unsupported("候选小区已不存在，请刷新列表。") }
        guard !state.cells.contains(where: { $0.index != index && $0.arfcn == arfcn && $0.pci == pci }) else {
            throw CPEError.unsupported("已存在相同频点和 PCI 的候选小区。")
        }
        let root = Self.listRoot + String(index) + "."
        let candidate = LockedCell(index: index, act: act, arfcn: arfcn, pci: pci)
        try Task.checkCancellation()
        try await write("set_value_by_xmlnode", data: .object([
            "url": .strings(["act": root + "act", "arfcn": root + "arfcn", "pci": root + "pci"]),
            "value": .strings(["act": String(act), "arfcn": String(arfcn), "pci": candidate.pciWireValue])
        ]))
        let result = try await readState()
        let expected = state.cells.map { $0.index == index ? candidate : $0 }
        try await verifyCandidates(result, expected: expected, switches: state)
        return result
    }

    public func deleteCell(index: Int) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        var state = try await readState()
        try ensureCandidateEditingAllowed(state)
        guard state.cells.contains(where: { $0.index == index }) else { throw CPEError.unsupported("候选小区已不存在，请刷新列表。") }
        if state.cells.count == 1 && state.cellLockEnabled {
            try await writeCellSwitch(false)
            state = try await readState()
            guard !state.cellLockEnabled else { throw CPEError.uncertain }
        }
        try Task.checkCancellation()
        try await write("del_xmlnode", data: .object(["url": .string(Self.listRoot), "index": .number(Double(index))]))
        let result = try await readState()
        try await verifyCandidates(result, expected: state.cells.filter { $0.index != index }, switches: state)
        return result
    }

    private func beginOperation() throws {
        guard !busy else { throw CPEError.busy }
        busy = true
    }

    private func readState() async throws -> RadioLockState {
        let settings = try await rpc.call("get_value_by_xmlnode", data: .strings([
            "LockEnable": Self.cellRoot + "LockEnable",
            "LockBandEnable": Self.settingsRoot + "LockBandEnable",
            "LTELockBAND": Self.settingsRoot + "LTELockBAND",
            "NRLockBAND": Self.settingsRoot + "NRLockBAND"
        ]), publicAccess: false)
        let table = try await rpc.call("get_xml_childnode_value", data: .object([
            "url": .string(Self.listRoot), "node": .strings(["act": "act", "arfcn": "arfcn", "pci": "pci"])
        ]), publicAccess: false)
        // A separate small batch follows the stock page. These subscriber details are
        // used only for the restriction check and are never retained in the returned state.
        let limits = try await rpc.call("get_value_by_xmlnode", data: .strings([
            "AirplaneEnable": Self.settingsRoot + "airplan_on",
            "CarrierLockEnable": Self.settingsRoot + "CarrierLockEnable",
            "CarrierSerialNum": Self.settingsRoot + "CarrierSerialNum",
            "IMSI": "X_FH_MobileNetwork.SIM.1.IMSI",
            "ModemModel": "DeviceInfo.ModemModel",
            "N79_Enable": "DeviceInfo.X_FH_N79_Enable"
        ]), publicAccess: false)
        let airplane = try Self.switchValue(limits["AirplaneEnable"])
        let carrier = try Self.switchValue(limits["CarrierLockEnable"])
        let serials = try Self.stringValue(limits["CarrierSerialNum"])
        let imsi = try Self.stringValue(limits["IMSI"])
        guard let modem = limits["ModemModel"].text else { throw CPEError.malformedResponse }
        let n79 = limits["N79_Enable"].text == "1"
        let restricted = carrier && !serials.split(separator: ",").contains { !$0.isEmpty && imsi.hasPrefix($0) }
        let northAmerican = modem == "RG620T-NA"
        let lte = northAmerican ? [2, 4, 5, 7, 12, 13, 14, 17, 25, 26, 29, 30, 38, 41, 42, 43, 46, 48, 66, 70, 71]
                               : [1, 3, 5, 7, 8, 20, 28, 32, 38, 40, 41, 42, 43]
        var nr = northAmerican ? [2, 5, 7, 12, 13, 14, 25, 26, 29, 30, 38, 41, 48, 66, 70, 71, 77, 78]
                              : [1, 3, 5, 7, 8, 20, 28, 38, 40, 41, 77, 78]
        if modem == "RG620T-EG" && n79 { nr.append(79) }
        return RadioLockState(
            cellLockEnabled: try Self.switchValue(settings["LockEnable"]),
            bandLockEnabled: try Self.switchValue(settings["LockBandEnable"]),
            cells: try Self.parseCells(table), lteBands: try Self.parseBands(settings["LTELockBAND"]),
            nrBands: try Self.parseBands(settings["NRLockBAND"]), airplaneModeEnabled: airplane,
            carrierRestricted: restricted, supportedLTEBands: lte, supportedNRBands: nr,
            allowsN79ARFCN: !northAmerican && !(modem == "RG620T-EG" && !n79))
    }

    private static func switchValue(_ value: JSONValue) throws -> Bool {
        guard let text = value.text, text == "0" || text == "1" else { throw CPEError.malformedResponse }
        return text == "1"
    }

    private static func stringValue(_ value: JSONValue) throws -> String {
        guard case .string(let text) = value else { throw CPEError.malformedResponse }
        return text
    }

    private static func parseBands(_ value: JSONValue) throws -> [Int] {
        let raw = try stringValue(value)
        if raw.isEmpty { return [] }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == numbers.count, numbers.allSatisfy({ $0 > 0 }) else { throw CPEError.malformedResponse }
        return Array(Set(numbers)).sorted()
    }

    private static func parseCells(_ value: JSONValue) throws -> [LockedCell] {
        guard case .array(let rows) = value["data"], rows.count <= 20 else { throw CPEError.malformedResponse }
        let result = try rows.map { row in
            guard let index = row["child_node_idx"].text.flatMap(Int.init), index > 0,
                  let act = row["act"].text.flatMap(Int.init), act == 1 || act == 2,
                  let arfcn = row["arfcn"].text.flatMap(Int.init), (0...875000).contains(arfcn) else { throw CPEError.malformedResponse }
            let pci = try parsePCI(row["pci"])
            return LockedCell(index: index, act: act, arfcn: arfcn, pci: pci)
        }
        guard Set(result.map(\.index)).count == result.count else { throw CPEError.malformedResponse }
        return result.sorted { $0.index < $1.index }
    }

    private static func parsePCI(_ value: JSONValue) throws -> Int? {
        if value == .string("") { return nil }
        guard let pci = value.text.flatMap(Int.init), (0...2000).contains(pci) else { throw CPEError.malformedResponse }
        return pci
    }

    private func ensureAllowed(_ state: RadioLockState) throws {
        if let reason = state.configurationBlockedReason { throw CPEError.unsupported(reason) }
    }

    private func ensureCandidateEditingAllowed(_ state: RadioLockState) throws {
        try ensureAllowed(state)
        guard !state.hasConflict else { throw CPEError.unsupported("锁定状态冲突，请先全部关闭。") }
    }

    private func validateCell(act: Int, arfcn: Int, pci: Int?, state: RadioLockState) throws {
        guard act == 1 || act == 2, (0...875000).contains(arfcn), pci.map({ (0...2000).contains($0) }) ?? true else {
            throw CPEError.unsupported("小区制式应为 LTE 或 NR，频点须在 0–875000，PCI 可留空或填写 0–2000。")
        }
        guard state.allowsN79ARFCN || !(693335...733333).contains(arfcn) else {
            throw CPEError.unsupported("当前设备配置不支持 N79 频点。")
        }
    }

    private func normalizedBands(lte: [Int], nr: [Int], state: RadioLockState) throws -> (lte: [Int], nr: [Int]) {
        var lteSet = Set(lte)
        if lteSet.contains(12) || lteSet.contains(17) { lteSet.formUnion([12, 17]) }
        let lte = lteSet.sorted(), nr = Set(nr).sorted()
        guard !lte.isEmpty || !nr.isEmpty else { throw CPEError.unsupported("请至少选择一个锁定频段。") }
        guard lte.allSatisfy(state.supportedLTEBands.contains), nr.allSatisfy(state.supportedNRBands.contains) else {
            throw CPEError.unsupported("所选频段不在当前设备的支持列表中。")
        }
        guard lte != [32], !(!lte.isEmpty && Set(lte).isSubset(of: [29, 46])), nr != [29] else {
            throw CPEError.unsupported("补充下行频段不能单独锁定，请同时选择其他频段。")
        }
        return (lte, nr)
    }

    private func writeCellSwitch(_ enabled: Bool) async throws {
        try await write("set_value_by_xmlnode", data: .object([
            "url": .strings(["Enable": Self.cellRoot + "LockEnable"]),
            "value": .strings(["Enable": enabled ? "1" : "0"])
        ]))
    }

    private func writeBandConfiguration(enabled: Bool, lte: [Int], nr: [Int]) async throws {
        try await write("set_value_by_xmlnode", data: .object([
            "url": .strings(["band4": Self.settingsRoot + "LTELockBAND", "band5": Self.settingsRoot + "NRLockBAND",
                             "enable": Self.settingsRoot + "LockBandEnable"]),
            "value": .strings(["band4": lte.map(String.init).joined(separator: ","),
                               "band5": nr.map(String.init).joined(separator: ","), "enable": enabled ? "1" : "0"])
        ]))
    }

    private func write(_ method: String, data: JSONValue) async throws {
        let reply = try await rpc.call(method, data: data, publicAccess: false)
        if reply["ERRORSTATUS"] != .null { throw CPEError.rejected }
        if reply["success"] == .bool(true) || reply["success"].text == "true" { return }
        if reply["success"] != .null { throw CPEError.rejected }
        guard reply["result"].text == "0" else { throw CPEError.uncertain }
    }

    private func turnOffBoth(_ state: RadioLockState) async throws -> RadioLockState {
        // Attempt both OFF commands even if the first fails; neither command can enable
        // a mode. The final independent read determines whether the repair succeeded.
        var writeError: (any Error)?
        do { try await writeCellSwitch(false) } catch { writeError = error }
        do { try await writeBandConfiguration(enabled: false, lte: state.lteBands, nr: state.nrBands) }
        catch { if writeError == nil { writeError = error } }
        let result = try await readState()
        guard !result.cellLockEnabled && !result.bandLockEnabled else { throw writeError ?? CPEError.uncertain }
        return result
    }

    private func rejectConflict(_ state: RadioLockState) async throws {
        if state.hasConflict {
            _ = try? await turnOffBoth(state)
            throw CPEError.uncertain
        }
    }

    private func verifyCandidates(_ result: RadioLockState, expected: [LockedCell], switches: RadioLockState) async throws {
        try await rejectConflict(result)
        func keys(_ cells: [LockedCell]) -> [String] { cells.map { "\($0.act):\($0.arfcn):\($0.pciWireValue)" }.sorted() }
        guard keys(result.cells) == keys(expected), result.cellLockEnabled == switches.cellLockEnabled,
              result.bandLockEnabled == switches.bandLockEnabled else { throw CPEError.uncertain }
    }
}

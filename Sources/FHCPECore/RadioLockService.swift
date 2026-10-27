import Foundation

/// The two firmware switches and their retained configuration are deliberately separate.
/// Candidates remain useful while their switch is off; a dual-enabled device needs repair.
public struct RadioLockState: Sendable, Equatable {
    public static let standardLTEBands = [1, 3, 5, 7, 8, 20, 28, 32, 38, 40, 41, 42, 43]
    public static let standardNRBands = [1, 3, 5, 7, 8, 20, 28, 38, 40, 41, 77, 78, 79]
    public var cellLockEnabled: Bool
    public var bandLockEnabled: Bool
    public var cells: [LockedCell]
    public var lteBands: [Int]
    public var nrBands: [Int]
    public var airplaneModeEnabled: Bool
    public var supportedLTEBands: [Int]
    public var supportedNRBands: [Int]
    /// Includes rows omitted from display, so they still count toward the write limit.
    var candidateRowCount: Int

    public init(cellLockEnabled: Bool = false, bandLockEnabled: Bool = false,
                cells: [LockedCell] = [], lteBands: [Int] = [], nrBands: [Int] = [],
                airplaneModeEnabled: Bool = false,
                supportedLTEBands: [Int] = RadioLockState.standardLTEBands,
                supportedNRBands: [Int] = RadioLockState.standardNRBands) {
        self.cellLockEnabled = cellLockEnabled; self.bandLockEnabled = bandLockEnabled
        self.cells = cells; self.lteBands = lteBands; self.nrBands = nrBands
        self.airplaneModeEnabled = airplaneModeEnabled
        self.supportedLTEBands = supportedLTEBands; self.supportedNRBands = supportedNRBands
        self.candidateRowCount = cells.count
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
        if airplaneModeEnabled { return "飞行模式已开启，暂时无法配置锁定。" }
        return nil
    }
}

/// Uses the stock LG6851F cellLockSet/frequencyLockSet contracts. Writes are never
/// retried; switching modes writes the target configuration and refreshes once.
public actor RadioLockService {
    private let rpc: any DeviceRPC
    private var busy = false
    private static let cellRoot = "X_FH_MobileNetwork.LockCellList."
    private static let listRoot = cellRoot + "LockCell."
    private static let settingsRoot = "X_FH_MobileNetwork.NetworkSettings."

    public init(rpc: any DeviceRPC) { self.rpc = rpc }
    private var nodes: FirmwareNodes { FirmwareNodes(rpc: rpc) }

    public func read() async throws -> RadioLockState {
        // Actor isolation alone does not cover the awaits inside the two-part read.
        // Hold the same gate as mutations so every returned state is one transaction.
        try beginOperation(); defer { busy = false }
        return try await readState()
    }

    public func setCellLockEnabled(_ enabled: Bool) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        if enabled { try await writeBandSwitch(false) }
        try await writeCellSwitch(enabled)
        return try await readState()
    }

    /// Adds the selected cell only when absent, enables the candidate list, and refreshes once.
    public func lockCell(act: Int, arfcn: Int, pci: Int?) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        try validateCell(act: act, arfcn: arfcn, pci: pci)
        let rows = try await nodes.child(root: Self.listRoot, fields: ["act": "act", "arfcn": "arfcn", "pci": "pci"])
        let cells = Self.parseCells(rows)
        let needsCandidate = !cells.contains { $0.arfcn == arfcn && $0.pci == pci }
        guard !needsCandidate || rows.count < 20 else {
            throw CPEError.unsupported("最多可配置 20 个候选小区。")
        }
        try await writeBandSwitch(false)
        if needsCandidate {
            try await writeCandidate(LockedCell(index: 0, act: act, arfcn: arfcn, pci: pci))
        }
        try await writeCellSwitch(true)
        return try await readState()
    }

    public func setBandLockEnabled(_ enabled: Bool, lte: [Int] = [], nr: [Int] = []) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        if enabled {
            let bands = try normalizedBands(lte: lte, nr: nr)
            try await writeCellSwitch(false)
            try await writeBandConfiguration(enabled: true, lte: bands.lte, nr: bands.nr)
        } else {
            try await writeBandSwitch(false)
        }
        return try await readState()
    }

    /// Turns off both switches while retaining the candidate and band selections.
    public func disableAll() async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        try await writeCellSwitch(false)
        try await writeBandSwitch(false)
        return try await readState()
    }

    public func addCell(act: Int, arfcn: Int, pci: Int?) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        let state = try await readState()
        try ensureCandidateEditingAllowed(state)
        try validateCell(act: act, arfcn: arfcn, pci: pci)
        guard state.candidateRowCount < 20 else { throw CPEError.unsupported("最多可配置 20 个候选小区。") }
        guard !state.cells.contains(where: { $0.arfcn == arfcn && $0.pci == pci }) else {
            throw CPEError.unsupported("已存在相同频点和 PCI 的候选小区。")
        }
        let candidate = LockedCell(index: 0, act: act, arfcn: arfcn, pci: pci)
        try await writeCandidate(candidate)
        let result = try await readState()
        return result
    }

    public func updateCell(index: Int, act: Int, arfcn: Int, pci: Int?) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        let state = try await readState()
        try ensureCandidateEditingAllowed(state)
        try validateCell(act: act, arfcn: arfcn, pci: pci)
        guard state.cells.contains(where: { $0.index == index }) else { throw CPEError.unsupported("候选小区已不存在，请刷新列表。") }
        guard !state.cells.contains(where: { $0.index != index && $0.arfcn == arfcn && $0.pci == pci }) else {
            throw CPEError.unsupported("已存在相同频点和 PCI 的候选小区。")
        }
        let root = Self.listRoot + String(index) + "."
        let candidate = LockedCell(index: index, act: act, arfcn: arfcn, pci: pci)
        try Task.checkCancellation()
        try await nodes.write("set_value_by_xmlnode", data: .object([
            "url": .strings(["act": root + "act", "arfcn": root + "arfcn", "pci": root + "pci"]),
            "value": .strings(["act": String(act), "arfcn": String(arfcn), "pci": candidate.pciWireValue])
        ]))
        let result = try await readState()
        return result
    }

    public func deleteCell(index: Int) async throws -> RadioLockState {
        try beginOperation(); defer { busy = false }
        var state = try await readState()
        try ensureCandidateEditingAllowed(state)
        guard state.cells.contains(where: { $0.index == index }) else { throw CPEError.unsupported("候选小区已不存在，请刷新列表。") }
        if state.cells.count == 1 && state.cellLockEnabled {
            try await writeCellSwitch(false)
            state.cellLockEnabled = false
        }
        try Task.checkCancellation()
        try await nodes.write("del_xmlnode", data: .object(["url": .string(Self.listRoot), "index": .number(Double(index))]))
        let result = try await readState()
        return result
    }

    private func beginOperation() throws {
        guard !busy else { throw CPEError.busy }
        busy = true
    }

    private func readState() async throws -> RadioLockState {
        let settings = try await nodes.read([
            "LockEnable": Self.cellRoot + "LockEnable",
            "LockBandEnable": Self.settingsRoot + "LockBandEnable",
            "LTELockBAND": Self.settingsRoot + "LTELockBAND",
            "NRLockBAND": Self.settingsRoot + "NRLockBAND",
            "AirplaneEnable": Self.settingsRoot + "airplan_on"
        ])
        let rows = try await nodes.child(root: Self.listRoot, fields: ["act": "act", "arfcn": "arfcn", "pci": "pci"])
        let (lteBands, skippedLTE) = Self.parseBands(settings["LTELockBAND"])
        let (nrBands, skippedNR) = Self.parseBands(settings["NRLockBAND"])
        FirmwareNodes.reportSkippedRows(skippedLTE + skippedNR, table: "锁定频段")
        var state = RadioLockState(
            cellLockEnabled: try FirmwareNodes.flag(settings["LockEnable"]),
            bandLockEnabled: try FirmwareNodes.flag(settings["LockBandEnable"]),
            cells: Self.parseCells(rows), lteBands: lteBands,
            nrBands: nrBands,
            airplaneModeEnabled: try FirmwareNodes.flag(settings["AirplaneEnable"]))
        state.candidateRowCount = rows.count
        return state
    }

    private static func parseBands(_ value: JSONValue) -> (bands: [Int], skipped: Int) {
        guard case .string(let raw) = value else { return ([], 1) }
        if raw.isEmpty { return ([], 0) }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        var skipped = 0
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int(trimmed), number > 0 {
                numbers.append(number)
            } else {
                skipped += 1
            }
        }
        return (Array(Set(numbers)).sorted(), skipped)
    }

    private static func parseCells(_ rows: [JSONValue]) -> [LockedCell] {
        var indices = Set<Int>()
        var result: [LockedCell] = []
        for row in rows {
            guard let index = row["child_node_idx"].text.flatMap(Int.init), index > 0,
                  let act = row["act"].text.flatMap(Int.init), act == 1 || act == 2,
                  let arfcn = row["arfcn"].text.flatMap(Int.init),
                  row["pci"] == .string("") || row["pci"].text.flatMap(Int.init) != nil,
                  indices.insert(index).inserted else { continue }
            result.append(LockedCell(index: index, act: act, arfcn: arfcn, pci: row["pci"].text.flatMap(Int.init)))
        }
        FirmwareNodes.reportSkippedRows(rows.count - result.count, table: "锁定小区表")
        return result.sorted { $0.index < $1.index }
    }

    private func ensureAllowed(_ state: RadioLockState) throws {
        if let reason = state.configurationBlockedReason { throw CPEError.unsupported(reason) }
    }

    private func ensureCandidateEditingAllowed(_ state: RadioLockState) throws {
        try ensureAllowed(state)
        guard !state.hasConflict else { throw CPEError.unsupported("锁定状态冲突，请先全部关闭。") }
    }

    private func validateCell(act: Int, arfcn: Int, pci: Int?) throws {
        guard act == 1 || act == 2, (0...875000).contains(arfcn), pci.map({ (0...2000).contains($0) }) ?? true else {
            throw CPEError.unsupported("小区制式应为 LTE 或 NR，频点须在 0–875000，PCI 可留空或填写 0–2000。")
        }
    }

    private func normalizedBands(lte: [Int], nr: [Int]) throws -> (lte: [Int], nr: [Int]) {
        let lte = Set(lte).sorted(), nr = Set(nr).sorted()
        guard !lte.isEmpty || !nr.isEmpty else { throw CPEError.unsupported("请至少选择一个锁定频段。") }
        guard lte.allSatisfy(RadioLockState.standardLTEBands.contains),
              nr.allSatisfy(RadioLockState.standardNRBands.contains) else {
            throw CPEError.unsupported("所选频段不在当前设备的支持列表中。")
        }
        return (lte, nr)
    }

    private func writeCandidate(_ cell: LockedCell) async throws {
        try await nodes.write("add_set_xmlnode", data: .object([
            "url": .string(Self.listRoot),
            "setNode": .object([
                "url": .strings(["act": "act", "arfcn": "arfcn", "pci": "pci"]),
                "value": .strings(["act": String(cell.act), "arfcn": String(cell.arfcn), "pci": cell.pciWireValue])
            ])
        ]))
    }

    private func writeCellSwitch(_ enabled: Bool) async throws {
        try await nodes.setMulti(urls: ["Enable": Self.cellRoot + "LockEnable"],
                                 values: ["Enable": FirmwareNodes.bool(enabled)])
    }

    private func writeBandSwitch(_ enabled: Bool) async throws {
        try await nodes.setMulti(urls: ["enable": Self.settingsRoot + "LockBandEnable"],
                                 values: ["enable": FirmwareNodes.bool(enabled)])
    }

    private func writeBandConfiguration(enabled: Bool, lte: [Int], nr: [Int]) async throws {
        try await nodes.setMulti(
            urls: ["band4": Self.settingsRoot + "LTELockBAND", "band5": Self.settingsRoot + "NRLockBAND",
                   "enable": Self.settingsRoot + "LockBandEnable"],
            values: ["band4": lte.map(String.init).joined(separator: ","),
                     "band5": nr.map(String.init).joined(separator: ","), "enable": FirmwareNodes.bool(enabled)])
    }

}

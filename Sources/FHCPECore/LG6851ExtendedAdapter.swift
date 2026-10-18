import Foundation

/// Read/write adapters for features whose firmware contract is only partially verified.
///
/// Each method is implemented against node names that the device itself publishes in
/// `get_xmlnode_js_file`, but the *response shape* for these containers has not been
/// confirmed on a live unit. They are therefore reachable only through an adapter that
/// reports the corresponding capability as disabled, and the UI shows them as 适配中.
/// No method here is called on a timer, and no write is retried after a timeout.
public struct LG6851ExtendedAdapter: Sendable {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    // MARK: SMS

    private static let recvRoot = "InternetGatewayDevice.X_FH_MobileNetwork.SMS_Recv."

    /// SMS conversations, grouped by the remote number.
    ///
    /// The firmware exposes a dedicated `get_sms_data` method (the web UI's
    /// `$multipost("get_value_by_xmlnode|get_sms_data")`). Its reply is::
    ///
    ///     session_item_1: { session_phone: "10010",
    ///                       message_item_21: { childnode, msg_content, time,
    ///                                          rcvorsend, isOpened, key_index }, ... }
    ///
    /// Earlier versions guessed per-field xmlnode names (`From`, `Content`,
    /// `ReceivedTime`), which this firmware never returns — that is why the inbox looked
    /// empty while the device reported 26 messages.
    public func threads() async throws -> [SMSThread] {
        let reply = try await rpc.call("get_sms_data", data: .null, publicAccess: false)
        guard case .object(let sessions) = reply else { return [] }

        var grouped: [String: [(order: Int, message: SMSMessage)]] = [:]
        let sortedSessionKeys = sessions.keys.sorted { Self.trailingIndex($0) < Self.trailingIndex($1) }

        for sessionKey in sortedSessionKeys {
            guard let value = sessions[sessionKey], case .object(let body) = value else { continue }
            let rawPhone = (body["session_phone"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let phone = rawPhone.isEmpty ? "未知号码" : rawPhone
            let messageKeys = body.keys
                .filter { $0.hasPrefix("message_item") }
                .sorted { Self.trailingIndex($0) < Self.trailingIndex($1) }

            for key in messageKeys {
                guard let item = body[key], case .object(let fields) = item else { continue }
                guard let content = fields["msg_content"]?.text,
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let rawDir = fields["rcvorsend"]?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                let isSent = (rawDir == "send" || rawDir == "1")
                let rawChild = fields["childnode"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                let node = (rawChild?.isEmpty == false) ? rawChild! : key
                // Sent and received messages live in separate firmware tables (`SMS_SendMsg` vs
                // `SMS_RecvMsg`) whose `childnode` indices both start at 1. Prefixing sent IDs
                // prevents SwiftUI `ForEach` identity collisions in mixed conversations while
                // keeping `childnode` intact for `markRead`.
                let uniqueID = isSent ? "send-\(node)" : node
                let normalizedDate = Self.normalizeDate(fields["time"]?.text)
                let order = Int(fields["key_index"]?.text ?? "") ?? Self.trailingIndex(key)
                let message = SMSMessage(
                    id: uniqueID,
                    sender: phone,
                    body: content,
                    date: normalizedDate,
                    isRead: isSent ? true : (fields["isOpened"]?.text == "1"),
                    isSent: isSent,
                    childnode: node
                )
                grouped[phone, default: []].append((order: order, message: message))
            }
        }

        var out: [SMSThread] = []
        for (phone, indexedMessages) in grouped where !indexedMessages.isEmpty {
            let sorted = indexedMessages.sorted { lhs, rhs in
                if lhs.message.date != rhs.message.date {
                    return lhs.message.date < rhs.message.date
                }
                return lhs.order < rhs.order
            }.map(\.message)
            out.append(SMSThread(phone: phone, messages: sorted))
        }
        // Most recent conversation first, with phone number as deterministic tie-breaker.
        out.sort { lhs, rhs in
            let leftDate = lhs.lastMessage?.date ?? ""
            let rightDate = rhs.lastMessage?.date ?? ""
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.phone < rhs.phone
        }
        return out
    }

    private static func trailingIndex(_ key: String) -> Int {
        guard let lastPart = key.split(separator: "_").last, let value = Int(lastPart) else { return 0 }
        return value
    }

    private static func normalizeDate(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "—"
        }
        return raw.replacingOccurrences(of: "-", with: "/")
    }

    /// Marks received messages as read using `set_single_by_xmlnode` per message node.
    public func markRead(childnodes: [String]) async throws {
        let nodes = childnodes.filter { !$0.isEmpty }
        guard !nodes.isEmpty else { return }
        for node in nodes {
            _ = try await rpc.call("set_single_by_xmlnode", data: .object([
                "url": .string(Self.recvRoot + "SMS_RecvMsg.\(node).isOpened"),
                "value": .string("1")
            ]), publicAccess: false)
        }
    }

    /// Sends one SMS through `send_msg`, the method the device's own SMS page uses.
    ///
    /// Encoding follows the firmware's rule: any character outside GSM 7-bit forces UCS-2.
    /// Never retried automatically; the caller keeps the draft on failure.
    @discardableResult
    public func sendSMS(to number: String, body: String) async throws -> Bool {
        let trimmedNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNumber.isEmpty, !trimmedBody.isEmpty else { throw CPEError.rejected }
        let needsUCS2 = trimmedBody.unicodeScalars.contains { $0.value >= 1000 }
        let reply = try await rpc.call("send_msg", data: .object([
            "recv_number": .string(trimmedNumber),
            "encode_schema": .string(needsUCS2 ? "GSM_UCS2" : "GSM_8BIT"),
            "content": .string(trimmedBody)
        ]), publicAccess: false)
        let result = reply["result"].text ?? ""
        // The device answers `result: 0` on success, and the web UI also treats an empty
        // result as success.
        guard result == "0" || result.isEmpty else { throw CPEError.rejected }
        return true
    }

    // MARK: Cell scan

    /// Discoverable cells, built from the firmware's parallel neighbour arrays.
    ///
    /// Live capture (RP0112) returned `PCI_NBR=101,423,676`, `BAND_NBR=N78,N78,N78`,
    /// `RSRP_NBR=-83,-89,-97`, `SINR_NBR=7,1,-8`, `EARFCN_NBR=634464,634464,634464`.
    /// The cells are index-aligned; the one whose PCI matches `NR_PCI` is the serving cell.
    /// No scan action exists in the verified API, so this reads the current neighbour set
    /// rather than triggering a fresh sweep.
    public func discoverableCells() async throws -> [CellRecord] {
        let r = try await rpc.call("get_value_by_xmlnode", data: .strings([
            "servingBand": "X_FH_MobileNetwork.RadioSignalParameter.NR_Band",
            "servingPci": "X_FH_MobileNetwork.RadioSignalParameter.NR_PCI",
            "servingRsrp": "X_FH_MobileNetwork.RadioSignalParameter.SSB_RSRP",
            "servingSinr": "X_FH_MobileNetwork.RadioSignalParameter.SSB_SINR",
            "servingArfcn": "X_FH_MobileNetwork.RadioSignalParameter.EARFCN_NBR",
            "lteBand": "X_FH_MobileNetwork.RadioSignalParameter.BAND",
            "pcis": "X_FH_MobileNetwork.RadioSignalParameter.PCI_NBR",
            "bands": "X_FH_MobileNetwork.RadioSignalParameter.BAND_NBR",
            "rsrps": "X_FH_MobileNetwork.RadioSignalParameter.RSRP_NBR",
            "sinrs": "X_FH_MobileNetwork.RadioSignalParameter.SINR_NBR",
            "arfcn": "X_FH_MobileNetwork.RadioSignalParameter.EARFCN_NBR"
        ]), publicAccess: false)

        return Self.parseCells(
            servingBand: r["servingBand"].text,
            servingPci: r["servingPci"].text,
            servingRsrp: r["servingRsrp"].text,
            servingSinr: r["servingSinr"].text,
            servingArfcn: r["servingArfcn"].text,
            lteBand: r["lteBand"].text,
            pcis: r["pcis"].text,
            bands: r["bands"].text,
            rsrps: r["rsrps"].text,
            sinrs: r["sinrs"].text,
            arfcns: r["arfcn"].text
        )
    }

    public static func parseCells(
        servingBand: String?,
        servingPci: String?,
        servingRsrp: String?,
        servingSinr: String?,
        servingArfcn: String?,
        lteBand: String?,
        pcis: String?,
        bands: String?,
        rsrps: String?,
        sinrs: String?,
        arfcns: String?
    ) -> [CellRecord] {
        let primaryPci = LG6851Adapter.single(servingPci)
        let pciList = Self.list(pcis)
        let bandList = Self.list(bands)
        let rsrpList = Self.list(rsrps)
        let sinrList = Self.list(sinrs)
        let arfcnList = Self.list(arfcns)
        var cells: [CellRecord] = []
        for (index, pci) in pciList.enumerated() {
            guard !pci.isEmpty else { continue }
            let tech = Self.tech(band: bandList.value(at: index))
            let isServing = pci == primaryPci
            cells.append(CellRecord(
                tech: tech,
                band: Self.normalizedBand(bandList.value(at: index), tech: tech),
                pci: pci,
                channel: arfcnList.value(at: index),
                rsrp: rsrpList.value(at: index),
                sinr: sinrList.value(at: index),
                state: isServing ? .serving : .neighbor
            ))
        }
        // If the neighbour arrays omit the serving cell, add it from the dedicated fields.
        if !cells.contains(where: { $0.state == .serving }), let pci = primaryPci {
            cells.insert(CellRecord(
                tech: .nr,
                band: LG6851Adapter.bandLabel(servingBand) ?? "—",
                pci: pci,
                channel: LG6851Adapter.single(servingArfcn),
                rsrp: LG6851Adapter.single(servingRsrp),
                sinr: LG6851Adapter.single(servingSinr),
                state: .serving), at: 0)
        }
        // LTE is only listed when the firmware reports an LTE band at all; the live unit
        // leaves it empty and still echoes a stale PCI, which must not become a row.
        if let lteBandLabel = LG6851Adapter.bandLabel(lteBand),
           !cells.contains(where: { $0.tech == .lte }) {
            cells.append(CellRecord(tech: .lte, band: lteBandLabel, pci: "—", state: .unconnected))
        }
        return cells
    }

    private static func list(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func tech(band: String?) -> RadioTech {
        guard let band = band?.uppercased() else { return .nr }
        if band.hasPrefix("N") { return .nr }
        if band.hasPrefix("B") { return .lte }
        return .nr
    }

    private static func normalizedBand(_ band: String?, tech: RadioTech) -> String {
        guard let band, !band.isEmpty else { return "—" }
        if band.uppercased().hasPrefix("N") || band.uppercased().hasPrefix("B") { return band }
        guard let number = Int(band) else { return band }
        return tech == .lte ? "B\(number)" : "n\(number)"
    }
}

/// Backend for `LockCoordinator` built on the verified cell/band nodes.
public struct LG6851LockBackend: LockBackend {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    private static let lockCell = "X_FH_MobileNetwork.LockCellList."
    private static let settings = "X_FH_MobileNetwork.NetworkSettings."

    public func readMode() async throws -> LockMode {
        let r = try await rpc.call("get_value_by_xmlnode", data: .strings([
            "cellEnable": Self.lockCell + "LockEnable",
            "bandEnable": Self.settings + "LockBandEnable",
            "lteBands": Self.settings + "LTELockBAND",
            "nrBands": Self.settings + "NRLockBAND"
        ]), publicAccess: false)
        let cells = r["cellEnable"].text == "1" ? try await LG6851Adapter.readLockedCells(rpc) : []
        return LG6851Adapter.lockMode(cellEnable: r["cellEnable"].text, cells: cells,
                                      bandEnable: r["bandEnable"].text,
                                      lte: r["lteBands"].text, nr: r["nrBands"].text)
    }

    public func disableLocks() async throws {
        try await write([
            Self.lockCell + "LockEnable": "0",
            Self.settings + "LockBandEnable": "0"
        ])
    }

    public func apply(_ mode: LockMode) async throws {
        switch mode {
        case .automatic:
            try await disableLocks()
        case .bands(let lte, let nr):
            try await write([
                Self.settings + "LockBandEnable": "1",
                Self.settings + "LTELockBAND": lte.map(String.init).joined(separator: ","),
                Self.settings + "NRLockBAND": nr.map(String.init).joined(separator: ",")
            ])
        case .cell(let rat, let arfcn, let pci):
            // The firmware locks onto a candidate *list*. Add the target if it is missing
            // (the stock page rejects duplicate arfcn+pci), then turn the list on. Existing
            // user entries are left untouched.
            let existing = try await LG6851Adapter.readLockedCells(rpc)
            if !existing.contains(where: { $0.arfcn == arfcn && $0.pci == pci }) {
                guard existing.count < 20 else { throw CPEError.rejected }
                let r = try await rpc.call("add_set_xmlnode", data: .object([
                    "url": .string(LG6851Adapter.lockCellList),
                    "setNode": .object([
                        "url": .strings(["act": "act", "arfcn": "arfcn", "pci": "pci"]),
                        "value": .strings(["act": String(rat), "arfcn": String(arfcn), "pci": pci.map(String.init) ?? ""])
                    ])
                ]), publicAccess: false)
                try Self.check(r)
            }
            try await write([Self.lockCell + "LockEnable": "1"])
        case .unknown:
            throw CPEError.rejected
        }
    }

    private static func check(_ r: JSONValue) throws {
        if let success = r["success"].text {
            guard success == "true" else { throw CPEError.uncertain }
        } else {
            let result = r["result"].text ?? ""
            guard result == "0" || result.isEmpty else { throw CPEError.uncertain }
        }
    }

    private func write(_ fields: [String: String]) async throws {
        for name in fields.keys.sorted() {
            let r = try await rpc.call("set_single_by_xmlnode",
                                       data: .object(["url": .string(name), "value": .string(fields[name]!)]),
                                       publicAccess: false)
            if let success = r["success"].text {
                guard success == "true" else { throw CPEError.uncertain }
            } else {
                let result = r["result"].text ?? ""
                guard result == "0" || result.isEmpty else { throw CPEError.uncertain }
            }
        }
    }
}

extension Array {
    /// Index-aligned parallel arrays from the firmware may be shorter than the PCI list;
    /// a missing element must read as "unknown", never crash.
    func value(at index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

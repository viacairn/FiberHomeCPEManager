import Foundation

public protocol DeviceAdapter: Sendable {
    func identify() async throws -> String
    func login(username: String, password: String) async throws
    func snapshot() async throws -> DeviceSnapshot
    func devices() async throws -> [ConnectedDevice]
}

/// LG6851F adapter.
///
/// Node names come from the device's own public `get_xmlnode_js_file` mapping, and the
/// value semantics follow the verified RP0112 contract and local regression fixtures.
/// The adapter never invents a node
/// name, and anything the device omits stays `nil` and renders as "—".
public struct LG6851Adapter: DeviceAdapter {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }

    // MARK: Identity & auth

    public func identify() async throws -> String {
        let r = try await rpc.call("get_device_info", data: .null, publicAccess: true)
        guard r["model_name"].text == "LG6851F" else {
            throw CPEError.unsupported("此型号尚未适配。当前已确认协议的型号为 LG6851F。")
        }
        return "LG6851F"
    }

    public func login(username: String, password: String) async throws {
        guard !username.isEmpty, !password.isEmpty else { throw CPEError.authentication }
        let r = try await rpc.call("DO_WEB_LOGIN", data: .strings(["username": username, "password": password]), publicAccess: true)
        // The firmware returns a numeric reason instead of a bare failure. Surfacing it is the
        // difference between "check your password" and "you are locked out for a minute",
        // which an earlier version collapsed into one generic message.
        let result = r["result"].text ?? ""
        guard result == "0" else { throw Self.loginError(forCode: result) }
        // A login result alone is insufficient: confirm a protected read actually works.
        let info = try await read(["model": "DeviceInfo.ModelName", "firmware": "DeviceInfo.SoftwareVersion"])
        guard info["model"].text == "LG6851F", info["firmware"].text != nil else { throw CPEError.authentication }
    }

    /// Maps `DO_WEB_LOGIN` result codes to the firmware's own wording.
    ///
    /// Codes come from the device's `login_res.js`:
    /// 1 already logged in elsewhere · 2 too many failures · 3 admin disabled ·
    /// 4 wrong username/password · 5 unknown.
    static func loginError(forCode code: String) -> CPEError {
        switch code {
        case "1": .loginRejected("当前已有用户在其他设备登录，请稍后再试。")
        case "2": .loginRejected("连续登录错误次数过多，请等待 1 分钟后再试。")
        case "3": .loginRejected("管理员账号已被禁用，需要恢复出厂设置才能解除。")
        case "4": .loginRejected("用户名或密码错误，请重试。")
        case "5": .loginRejected("设备返回未知错误，请稍后重试。")
        default: .loginRejected("登录被拒绝（设备返回代码 \(code)）。")
        }
    }

    public func read(_ fields: [String: String]) async throws -> JSONValue {
        try await FirmwareNodes(rpc: rpc).read(fields)
    }

    // MARK: Node roots (case-sensitive, as the firmware serves them)

    static let radio = "X_FH_MobileNetwork.RadioSignalParameter."
    static let traffic = "X_FH_MobileNetwork.TrafficStats."
    static let sim = "X_FH_MobileNetwork.SIM.1."
    static let networkSettings = "X_FH_MobileNetwork.NetworkSettings."
    static let lockCell = "X_FH_MobileNetwork.LockCellList."
    static let temperature = "X_FH_MobileNetwork.Temperature."
    static let wan = "InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANIPConnection.1."
    static let smsRecv = "InternetGatewayDevice.X_FH_MobileNetwork.SMS_Recv."

    // MARK: Snapshot

    public func snapshot() async throws -> DeviceSnapshot {
        var fields: [String: String] = [
            "model": "DeviceInfo.ModelName",
            "firmware": "DeviceInfo.SoftwareVersion",
            // `Total_Uptime` does not exist on RP0112; `UpTime` does (verified 2026-10-18).
            "uptime": "DeviceInfo.UpTime",
            "manufacturer": "DeviceInfo.Manufacturer",
            "hardware": "DeviceInfo.HardwareVersion",
            "wanDevice": "DeviceInfo.X_FH_CurrentWANDevice",
            "aggregation": "DeviceInfo.X_FH_Multiwan_Aggregation.Enable",
            // Uplink usability is proven by the WAN connection state, not by SIM flags.
            "wanStatus": Self.wan + "ConnectionStatus",
            "ethernetStatus": "InternetGatewayDevice.WANDevice.2.WANConnectionDevice.1.WANIPConnection.1.ConnectionStatus",
            "ethernetAddress": "InternetGatewayDevice.WANDevice.2.WANConnectionDevice.1.WANIPConnection.1.ExternalIPAddress",
            "wanAddress": Self.wan + "ExternalIPAddress",
            "wanUptime": Self.wan + "Uptime",
            "carrier": Self.sim + "CarrierName",
            "simPlmn": Self.sim + "plmn",
            "networkMode": Self.sim + "NetworkMode",
            "simStatus": Self.sim + "SIMStatus",
            "registerStatus": Self.sim + "RegisterStatus",
            "temperature": Self.temperature + "Modem5GTemperature",
            "fan": "X_FH_MobileNetwork.FanAutoConfig.mode",
            "smsCount": Self.smsRecv + "SMSRecvNumberOfEntries",
            "cellLockEnable": Self.lockCell + "LockEnable",
            "bandLockEnable": Self.networkSettings + "LockBandEnable",
            "bandLockLte": Self.networkSettings + "LTELockBAND",
            "bandLockNr": Self.networkSettings + "NRLockBAND"
        ]
        for key in ["WorkMode", "RSRP", "RSRQ", "SINR", "RSSI", "BAND", "PCI", "ECGI", "TAC", "PLMN",
                    "SSB_RSRP", "SSB_RSRQ", "SSB_SINR", "SSB_RSSI", "NR_Band", "NR_PCI", "NCGI",
                    "Signal_Level", "NR_QCI", "QCI", "NR_CQI", "LTE_CQI", "NR_Power", "LTE_Power",
                    "EARFCN_NBR", "PCI_NBR", "RSRP_NBR", "BAND_NBR", "SINR_NBR", "DL_AMBR", "UL_AMBR"] {
            fields["radio.\(key)"] = Self.radio + key
        }
        // Carrier aggregation lives in a second request: the core batch plus 20 more nodes
        // exceeded what this firmware answers in one call.
        let networkInfo = "X_FH_MobileNetwork.NetworkInfo."
        var carrierFields: [String: String] = [
            "carrier.sccNumbers": networkInfo + "SCCInfos.sccNumbers",
            "carrier.pccBand": networkInfo + "PCCInfo.pccBand",
            "carrier.pccPci": networkInfo + "PCCInfo.pccPci",
            "carrier.pccArfcn": networkInfo + "PCCInfo.pccArfcn"
        ]
        for index in 1...4 {
            carrierFields["carrier.scc\(index)Band"] = networkInfo + "SCCInfos.\(index).sccBand"
            carrierFields["carrier.scc\(index)Pci"] = networkInfo + "SCCInfos.\(index).sccPci"
            carrierFields["carrier.scc\(index)Arfcn"] = networkInfo + "SCCInfos.\(index).sccArfcn"
            carrierFields["carrier.scc\(index)State"] = networkInfo + "SCCInfos.\(index).sccState"
        }

        for key in ["TodayTotalBytes", "MonthTotalBytes", "TodayTotalRxBytes", "TodayTotalTxBytes",
                    "SpeedRxBytes", "SpeedTxBytes"] {
            fields["traffic.\(key)"] = Self.traffic + key
        }

        let r = try await read(fields)
        guard let model = r["model"].text, let firmware = r["firmware"].text else { throw CPEError.malformedResponse }

        var s = DeviceSnapshot()
        s.model = model
        s.firmware = firmware
        s.manufacturer = r["manufacturer"].text
        s.hardware = r["hardware"].text
        s.uptime = Self.single(r["uptime"].text)
        s.operatorName = r["carrier"].text
        s.plmn = r["simPlmn"].text ?? Self.single(r["radio.PLMN"].text)
        s.temperature = Self.celsius(r["temperature"].text)
        s.fanModeRaw = Self.single(r["fan"].text)
        s.smsCount = r["smsCount"].text.flatMap(Int.init)

        let workMode = r["radio.WorkMode"].text ?? ""
        let nrBand = Self.bandLabel(r["radio.NR_Band"].text)
        let lteBand = Self.bandLabel(r["radio.BAND"].text)
        // The live unit reports WorkMode as the *network architecture* ("SA"), not the
        // radio access technology, so RAT is derived from which band the device reports.
        s.activeTech = Self.tech(nrBand: nrBand, lteBand: lteBand, workMode: workMode)
        s.network = Self.networkLabel(tech: s.activeTech)
        s.nrMode = Self.nrMode(workMode)

        s.nr.rsrp = Self.single(r["radio.SSB_RSRP"].text)
        s.nr.rsrq = Self.single(r["radio.SSB_RSRQ"].text)
        s.nr.sinr = Self.single(r["radio.SSB_SINR"].text)
        s.nr.rssi = Self.single(r["radio.SSB_RSSI"].text)
        s.nr.band = nrBand
        s.nr.pci = Self.single(r["radio.NR_PCI"].text)
        s.nr.cell = Self.single(r["radio.NCGI"].text)
        s.nr.arfcn = Self.single(r["radio.EARFCN_NBR"].text)
        s.nr.cqi = Self.single(r["radio.NR_CQI"].text)
        s.nr.power = Self.single(r["radio.NR_Power"].text)
        s.nr.qci = Self.single(r["radio.NR_QCI"].text)
        s.nr.tac = Self.single(r["radio.TAC"].text)
        s.nr.plmn = Self.single(r["radio.PLMN"].text)
        s.nr.dlAmbrKbps = Self.single(r["radio.DL_AMBR"].text).flatMap(Double.init)
        s.nr.ulAmbrKbps = Self.single(r["radio.UL_AMBR"].text).flatMap(Double.init)

        // LTE readings are only meaningful when an LTE band is actually reported. The
        // live unit leaves BAND empty while still echoing a stale PCI/RSRP of zero.
        if lteBand != nil {
            s.lte.rsrp = Self.single(r["radio.RSRP"].text)
            s.lte.rsrq = Self.single(r["radio.RSRQ"].text)
            s.lte.sinr = Self.single(r["radio.SINR"].text)
            s.lte.rssi = Self.single(r["radio.RSSI"].text)
            s.lte.band = lteBand
            s.lte.pci = Self.single(r["radio.PCI"].text)
            s.lte.cell = Self.single(r["radio.ECGI"].text)
            s.lte.cqi = Self.single(r["radio.LTE_CQI"].text)
            s.lte.power = Self.single(r["radio.LTE_Power"].text)
            s.lte.tac = Self.single(r["radio.TAC"].text)
            s.lte.plmn = Self.single(r["radio.PLMN"].text)
        }

        s.todayBytes = r["traffic.TodayTotalBytes"].double
        s.todayKnown = s.todayBytes != nil
        s.monthBytes = r["traffic.MonthTotalBytes"].double
        s.monthKnown = s.monthBytes != nil
        s.receivedBytes = r["traffic.TodayTotalRxBytes"].text.flatMap(UInt64.init)
        s.sentBytes = r["traffic.TodayTotalTxBytes"].text.flatMap(UInt64.init)
        // Live throughput: bytes per second, refreshed on every poll.
        s.rxBytesPerSecond = r["traffic.SpeedRxBytes"].text.flatMap(Double.init)
        s.txBytesPerSecond = r["traffic.SpeedTxBytes"].text.flatMap(Double.init)

        let cellLockOn = r["cellLockEnable"].text == "1"
        if cellLockOn {
            s.lockedCells = (try? await Self.readLockedCells(rpc)) ?? []
        }
        s.lockMode = Self.lockMode(
            cellEnable: r["cellLockEnable"].text, cells: s.lockedCells,
            bandEnable: r["bandLockEnable"].text, lte: r["bandLockLte"].text, nr: r["bandLockNr"].text)

        // WANDevice.1 = cellular, WANDevice.2 = Ethernet. Only `Connected` counts: an
        // unplugged Ethernet port reports `Unconfigured` with an empty address.
        s.wanConnected = Self.isUp(r["wanStatus"].text)
        s.ethernetConnected = Self.isUp(r["ethernetStatus"].text)
        s.wanAddress = s.wanConnected ? Self.address(r["wanAddress"].text) : nil
        s.ethernetAddress = s.ethernetConnected ? Self.address(r["ethernetAddress"].text) : nil
        s.wanUptime = r["wanUptime"].text.flatMap(Double.init)
        s.uplink = Self.uplinkMode(aggregation: r["aggregation"].text,
                                   wanDevice: r["wanDevice"].text,
                                   wanConnected: s.wanConnected || s.ethernetConnected)
        // A green lamp means at least one WAN positively reports `Connected`.
        s.uplinkAvailable = s.wanConnected || s.ethernetConnected
        s.uplinkEvidence = "蜂窝\(s.wanConnected ? "已连接" : "未连接") · 以太网\(s.ethernetConnected ? "已连接" : "未接入")"

        s.signalBars = Self.signalBars(signalLevel: r["radio.Signal_Level"].text, snapshot: s)
        s.cells = LG6851ExtendedAdapter.parseCells(
            servingBand: r["radio.NR_Band"].text,
            servingPci: r["radio.NR_PCI"].text,
            servingRsrp: r["radio.SSB_RSRP"].text,
            servingSinr: r["radio.SSB_SINR"].text,
            servingArfcn: r["radio.EARFCN_NBR"].text,
            lteBand: r["radio.BAND"].text,
            pcis: r["radio.PCI_NBR"].text,
            bands: r["radio.BAND_NBR"].text,
            rsrps: r["radio.RSRP_NBR"].text,
            sinrs: r["radio.SINR_NBR"].text,
            arfcns: r["radio.EARFCN_NBR"].text
        )
        let carrierReply = (try? await read(carrierFields)) ?? .null
        s.carriers = Self.carriers(carrierReply)
        s.capabilities = CapabilitySet(bands: true, cells: true, sms: (s.smsCount ?? 0) > 0)
        return s
    }

    // MARK: Devices

    public func devices() async throws -> [ConnectedDevice] {
        let rows = try await FirmwareNodes(rpc: rpc).child(.object([
            "url": .string("LANDevice.1.Hosts.Host."),
            "num": .number(256),
            "node": .strings(["name": "HostName", "devName": "DevName", "mac": "MACAddress",
                              "ip": "IPAddress", "active": "Active", "interface": "Layer2Interface",
                              "type": "DeviceType", "online": "OnlineTime"])
        ]))
        return rows.enumerated().compactMap { index, row in
            // The unit returns every historical host; only Active=1 is online.
            guard row["active"].text == "1" else { return nil }
            let hostName = row["name"].text
            let deviceName = row["devName"].text
            // DevName is the human label; HostName is often literally "unknown".
            let display: String = {
                if let deviceName, deviceName != "unknown", !deviceName.isEmpty { return deviceName }
                if let hostName, hostName != "unknown", !hostName.isEmpty { return hostName }
                return "未命名设备"
            }()
            let ip = row["ip"].text ?? "—"
            return ConnectedDevice(
                id: row["mac"].text ?? "device-\(index)",
                name: display,
                ip: ip.isEmpty ? "—" : ip,
                access: Self.accessKind(from: row["interface"].text),
                mac: row["mac"].text,
                hostname: hostName,
                deviceType: row["type"].text,
                onlineSeconds: row["online"].text.flatMap(Double.init)
            )
        }
    }

    /// The live unit returns `WLANConfiguration.N.OperatingFrequencyBand` as an empty
    /// string, so the band cannot be read. What *was* observed: index 5 carries the
    /// phones/tablets/Macs/AppleTV and index 1 carries the Midea appliances, Aqara camera
    /// and robot vacuum — the same split the stock UI shows as 5G / 2.4G. The mapping is an
    /// observed convention, documented as such, and anything outside it stays unknown.
    static func accessKind(from path: String?) -> AccessKind {
        guard let path, !path.isEmpty else { return .unknown }
        if path.contains("LANEthernetInterfaceConfig") { return .wired }
        guard path.contains("WLANConfiguration") else { return .unknown }
        guard let range = path.range(of: "WLANConfiguration.") else { return .unknown }
        let digits = path[range.upperBound...].prefix { $0.isNumber }
        switch String(digits) {
        case "5": return .wifi5G
        case "1": return .wifi24G
        default: return .unknown
        }
    }

    // MARK: Parsing helpers

    /// Multi-valued firmware fields arrive comma-separated (e.g. `EARFCN_NBR` =
    /// `634464,634464,634464,634464`). Display uses the first element; a bare value with
    /// no separator is returned unchanged.
    static func single(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.split(separator: ",").first.map(String.init) ?? raw
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Temperatures are reported in thousandths of a degree (31708 → 31.7 ℃).
    static func celsius(_ raw: String?) -> String? {
        guard let raw, let value = Double(raw), value > 0 else { return nil }
        return value > 1000 ? String(format: "%.1f", value / 1000) : String(format: "%.0f", value)
    }

    static func networkLabel(tech: RadioTech) -> String {
        switch tech {
        case .nr: "5G"
        case .lte: "4G"
        case .wcdma: "3G"
        case .unknown: "—"
        }
    }

    /// `workMode` is the architecture ("SA"/"NSA"); band presence decides the RAT.
    static func tech(nrBand: String?, lteBand: String?, workMode: String) -> RadioTech {
        if nrBand != nil { return .nr }
        if lteBand != nil { return .lte }
        let value = workMode.uppercased()
        if value.contains("NR") { return .nr }
        if value.contains("LTE") || value.contains("4G") { return .lte }
        if value.contains("WCDMA") || value.contains("3G") { return .wcdma }
        return .unknown
    }

    /// "SA" / "NSA" are shown next to the RAT, never in place of it.
    static func nrMode(_ workMode: String) -> String? {
        let value = workMode.uppercased()
        if value == "SA" { return "SA" }
        if value == "NSA" { return "NSA" }
        return nil
    }

    static func bandLabel(_ raw: String?) -> String? {
        guard let raw = single(raw) else { return nil }
        if raw == "0" { return nil }
        if raw.uppercased().hasPrefix("N") || raw.uppercased().hasPrefix("B") { return raw }
        guard let number = Int(raw) else { return raw }
        // NR bands are commonly n1…n261; LTE B1…B71.
        return number > 71 ? "n\(number)" : "B\(number)"
    }

    static func lockMode(cellEnable: String?, cells: [LockedCell],
                         bandEnable: String?, lte: String?, nr: String?) -> LockMode {
        if cellEnable == "1" && bandEnable == "1" { return .unknown }
        if cellEnable == "1" {
            // The firmware locks onto the candidate list; the first entry summarises it.
            guard let first = cells.first else { return .unknown }
            return .cell(rat: first.act, arfcn: first.arfcn, pci: first.pci)
        }
        if bandEnable == "1" {
            return .bands(lte: intList(lte), nr: intList(nr))
        }
        if cellEnable == "0" || bandEnable == "0" { return .automatic }
        return .unknown
    }

    static let lockCellList = lockCell + "LockCell."

    /// Reads `LockCellList.LockCell.{i}.act/arfcn/pci` the way the stock page does
    /// (`get_xml_childnode_value`, lower-case field names).
    static func readLockedCells(_ rpc: any DeviceRPC) async throws -> [LockedCell] {
        let rows = try await FirmwareNodes(rpc: rpc).child(root: lockCellList,
                                                         fields: ["act": "act", "arfcn": "arfcn", "pci": "pci"])
        return parseLockedCells(.object(["data": .array(rows)]))
    }

    static func parseLockedCells(_ r: JSONValue) -> [LockedCell] {
        guard case .array(let rows) = r["data"] else { return [] }
        return rows.enumerated().compactMap { offset, row in
            guard let arfcn = row["arfcn"].text.flatMap(Int.init) else { return nil }
            let pci: Int?
            if row["pci"] == .string("") { pci = nil }
            else {
                guard let value = row["pci"].text.flatMap(Int.init) else { return nil }
                pci = value
            }
            let index = row["child_node_idx"].text.flatMap(Int.init) ?? (offset + 1)
            return LockedCell(index: index, act: row["act"].text.flatMap(Int.init) ?? 2, arfcn: arfcn, pci: pci)
        }
    }

    /// Empty strings and `0.0.0.0` mean "no address".
    static func address(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != "0.0.0.0" else { return nil }
        return value
    }

    static func intList(_ raw: String?) -> [Int] {
        guard let raw else { return [] }
        return raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    static func isUp(_ status: String?) -> Bool {
        guard let status else { return false }
        let value = status.lowercased()
        return value == "connected" || value == "up" || value == "1"
    }

    /// Exactly one uplink mode is reported. Aggregation is only claimed when the firmware
    /// switch is on; the mode otherwise follows what actually carries the WAN connection.
    /// Primary carrier plus up to four secondary carriers.
    ///
    /// The firmware reports an empty slot as `-`, so a slot only becomes a component when it
    /// carries a band/PCI/ARFCN. `sccNumbers` is advisory: the per-slot fields are the truth.
    static func carriers(_ r: JSONValue) -> [CarrierComponent] {
        func clean(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value != "-", value != "NULL" else { return nil }
            return value
        }
        var out: [CarrierComponent] = []
        let primary = CarrierComponent(
            role: .primary,
            band: clean(r["carrier.pccBand"].text),
            pci: clean(r["carrier.pccPci"].text),
            arfcn: clean(r["carrier.pccArfcn"].text),
            state: "active")
        if primary.isPresent { out.append(primary) }
        for index in 1...4 {
            let component = CarrierComponent(
                role: .secondary, index: index,
                band: clean(r["carrier.scc\(index)Band"].text),
                pci: clean(r["carrier.scc\(index)Pci"].text),
                arfcn: clean(r["carrier.scc\(index)Arfcn"].text),
                state: clean(r["carrier.scc\(index)State"].text))
            if component.isPresent { out.append(component) }
        }
        return out
    }

    static func uplinkMode(aggregation: String?, wanDevice: String?, wanConnected: Bool) -> UplinkMode {
        if aggregation == "1" { return .aggregation }
        guard wanConnected else { return .unknown }
        guard let wanDevice else { return .cellular }
        // Live unit: `InternetGatewayDevice.WANDevice.1.` = cellular, `.2.` = Ethernet.
        if wanDevice.contains("WANDevice.2.") { return .broadband }
        let value = wanDevice.lowercased()
        if value.contains("pon") || value.contains("eth") || value.contains("dsl") { return .broadband }
        return .cellular
    }

    static func signalBars(signalLevel: String?, snapshot: DeviceSnapshot) -> Int? {
        if let level = Int(signalLevel ?? ""), (0...4).contains(level) { return level }
        let radio = snapshot.servingRadio
        return MetricFormatter.bars(rsrp: MetricFormatter.number(radio.rsrp),
                                    sinr: MetricFormatter.number(radio.sinr),
                                    isNR: snapshot.activeTech == .nr)
    }
}

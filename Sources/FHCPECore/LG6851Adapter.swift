import Foundation

public protocol DeviceAdapter: Sendable {
    func identify() async throws -> String
    func login(username: String, password: String) async throws
    func snapshot() async throws -> DeviceSnapshot
    func devices() async throws -> [ConnectedDevice]
}
public struct LG6851Adapter: DeviceAdapter {
    public let rpc: any DeviceRPC
    public init(rpc: any DeviceRPC) { self.rpc = rpc }
    public func identify() async throws -> String {
        let r = try await rpc.call("get_device_info", data: .null, publicAccess: true)
        guard r["model_name"].text == "LG6851F" else { throw CPEError.unsupported("此型号尚未适配。当前已确认协议的型号为 LG6851F。") }
        return "LG6851F"
    }
    public func login(username: String, password: String) async throws {
        guard !username.isEmpty, !password.isEmpty else { throw CPEError.authentication }
        let r = try await rpc.call("DO_WEB_LOGIN", data: .strings(["username":username,"password":password]), publicAccess: true)
        guard r["result"].text == "0" else { throw CPEError.authentication }
        // A cookie or login result alone is insufficient: confirm a protected read.
        let info = try await read(["model":"DeviceInfo.ModelName", "firmware":"DeviceInfo.SoftwareVersion"])
        guard info["model"].text == "LG6851F", info["firmware"].text != nil else { throw CPEError.authentication }
    }
    public func read(_ fields: [String: String]) async throws -> JSONValue {
        try await rpc.call("get_value_by_xmlnode", data: .strings(fields), publicAccess: false)
    }
    public func snapshot() async throws -> DeviceSnapshot {
        var fields = ["model":"DeviceInfo.ModelName", "firmware":"DeviceInfo.SoftwareVersion", "uptime":"DeviceInfo.UpTime", "temperature":"X_FH_MobileNetwork.Temperature.Modem5GTemperature"]
        let radio = "X_FH_MobileNetwork.RadioSignalParameter."
        for key in ["WorkMode","RSRP","RSRQ","SINR","BAND","PCI","ECGI","SSB_RSRP","SSB_RSRQ","SSB_SINR","NR_Band","NR_PCI","NCGI"] { fields[key] = radio + key }
        for key in ["TodayTotalBytes","MonthTotalBytes","TodayTotalRxBytes","TodayTotalTxBytes"] { fields[key] = "X_FH_MobileNetwork.TrafficStats." + key }
        let r = try await read(fields)
        guard let model = r["model"].text, let firmware = r["firmware"].text else { throw CPEError.malformedResponse }
        var s = DeviceSnapshot(); s.model = model; s.firmware = firmware; s.network = r["WorkMode"].text ?? "—"; s.uptime = r["uptime"].text
        s.temperature = r["temperature"].text
        s.lte.rsrp = r["RSRP"].text; s.lte.rsrq = r["RSRQ"].text; s.lte.sinr = r["SINR"].text; s.lte.band = r["BAND"].text; s.lte.pci = r["PCI"].text; s.lte.cell = r["ECGI"].text
        s.nr.rsrp = r["SSB_RSRP"].text; s.nr.rsrq = r["SSB_RSRQ"].text; s.nr.sinr = r["SSB_SINR"].text; s.nr.band = r["NR_Band"].text; s.nr.pci = r["NR_PCI"].text; s.nr.cell = r["NCGI"].text
        s.todayBytes = r["TodayTotalBytes"].double; s.monthBytes = r["MonthTotalBytes"].double
        s.receivedBytes = r["TodayTotalRxBytes"].text.flatMap(UInt64.init)
        s.sentBytes = r["TodayTotalTxBytes"].text.flatMap(UInt64.init)
        return s
    }
    public func devices() async throws -> [ConnectedDevice] {
        let r = try await rpc.call("get_xml_childnode_value", data: .object([
            "url":.string("LANDevice.1.Hosts.Host."), "num":.number(256),
            "node":.strings(["name":"HostName", "mac":"MACAddress", "ip":"IPAddress", "active":"Active", "interface":"Layer2Interface"])
        ]), publicAccess: false)
        guard case .array(let rows) = r["data"] else { throw CPEError.malformedResponse }
        return rows.enumerated().compactMap { index, row in
            guard row["active"].text == "1" else { return nil }
            return ConnectedDevice(id: "\(row["mac"].text ?? "unknown")-\(index)", name: row["name"].text ?? "未命名设备", ip: row["ip"].text ?? "—", interface: Self.interfaceLabel(row["interface"].text))
        }
    }
    public static func interfaceLabel(_ path: String?) -> String {
        guard let path else { return "—" }
        if path.contains("WLANConfiguration") { return "Wi-Fi" }
        if path.contains("LANEthernetInterfaceConfig") { return "以太网" }
        return "其他连接"
    }
    public func write(_ fields: [String:String]) async throws {
        let names = fields.keys.sorted()
        var urls: [String:JSONValue] = [:], values: [String:JSONValue] = [:]
        for (i,name) in names.enumerated() { urls["v\(i)"] = .string(name); values["v\(i)"] = .string(fields[name]!) }
        let r = try await rpc.call("set_value_by_xmlnode", data: .object(["url":.object(urls),"value":.object(values)]), publicAccess: false)
        guard r["result"].text == "0" else { throw CPEError.uncertain }
    }
}

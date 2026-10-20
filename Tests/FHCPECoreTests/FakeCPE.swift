import Foundation
import Network
import Security
import FHCPECore

/// A local stand-in for the CPE management console, used to verify the client end-to-end
/// (handshake → login → encrypted reads → device list) without touching the real router
/// and without any real credentials.
///
/// It implements the firmware wire format that `LocalTransport` speaks, reusing the same
/// independent `FHCodec`. The fixture values come from the field mapping the device itself
/// publishes in `get_xmlnode_js_file`, so a successful exchange proves the client's parsing
/// and request construction, not a shared guess between client and server.
final class FakeCPE: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fakecpe")
    private let seed = "hU3S9"
    private let sessionID = String((0..<64).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()! })
    private var loginAccepted = false
    private var requests: [String] = []

    let port: UInt16
    /// Serialises the diagnostic trail so a failing test can report the HTTP exchange.
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
    private let logBox = LogBox()
    var log: [String] { logBox.snapshot }
    private var onRequestStorage: (@Sendable (String) -> Void)?
    var onRequest: (@Sendable (String) -> Void)? {
        get { onRequestStorage }
        set { onRequestStorage = newValue }
    }
    private func trace(_ event: String) { logBox.append(event); onRequestStorage?(event) }

    init(port: UInt16 = 0) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if port == 0 {
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        }
        self.port = port
    }

    func start() throws -> UInt16 {
        // A listener started on port 0 exposes the OS-assigned port only once it reaches
        // `.ready`, so block on that transition rather than polling `listener.port`.
        let ready = DispatchSemaphore(value: 0)
        final class FailureBox: @unchecked Sendable { var text: String? }
        let box = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): box.text = "\(error)"; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success else {
            throw CPEError.unsupported("fake server did not become ready")
        }
        if let failure = box.text { throw CPEError.unsupported("fake server failed: \(failure)") }
        guard let resolved = listener.port?.rawValue, resolved != 0 else {
            throw CPEError.unsupported("fake server has no usable port")
        }
        return resolved
    }

    func stop() { listener.cancel() }

    /// Mirrors the RP0112 heartbeat's expired-session status after another entry logs in.
    private var sessionExpired = false
    func expireSession() { queue.sync { sessionExpired = true } }
    private var supportsHeartbeat = true
    func disableHeartbeat() { queue.sync { supportsHeartbeat = false } }
    private var supportsActivityRenewal = true
    func disableActivityRenewal() { queue.sync { supportsActivityRenewal = false } }

    // MARK: HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let (request, body) = Self.parseHTTP(buffer) {
                let response = self.respond(to: request, body: body)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete || error != nil || buffer.count > 4 * 1024 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private static func parseHTTP(_ data: Data) -> (Request, Data)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        if length > 0, data.count < bodyStart + length { return nil }
        let body = length > 0 ? Data(data[bodyStart..<(bodyStart + length)]) : Data()
        return (Request(method: String(parts[0]), path: String(parts[1])), body)
    }

    struct Request { let method: String; let path: String }

    private func respond(to request: Request, body: Data) -> Data {
        let url = URL(string: "http://x\(request.path)")!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ajaxmethod = query.first { $0.name == "ajaxmethod" }?.value

        if request.path == "/fh_api/tmp/heartbeat" {
            trace("HEARTBEAT")
            guard supportsHeartbeat else { return http(404, Data()) }
            return loginAccepted && !sessionExpired
                ? http(200, Data("1\n".utf8)) : http(418, Data("0\n".utf8))
        }

        if request.path == "/fh_api/tmp/refresh_timeout" {
            trace("REFRESH_TIMEOUT")
            guard supportsActivityRenewal else { return http(404, Data()) }
            return loginAccepted && !sessionExpired ? http(200, Data()) : http(418, Data("0\n".utf8))
        }

        if request.path.hasPrefix("/fh_api/tmp/FHNCAPIS"), request.method == "GET" {
            switch ajaxmethod {
            case "is_encrypt":
                let envelope = encryptSeed()
                return json(["data": "XXXXXX" + envelope])
            case "get_refresh_sessionid":
                return json(["sessionid": sessionID])
            default:
                return http(404, Data())
            }
        }
        if request.path.hasPrefix("/fh_api/sign/") {
            let method = request.path.components(separatedBy: "/").last ?? ""
            requests.append(method)
            guard let object = decodeEnvelope(body), object["ajaxmethod"].text == method else {
                trace("SIGN_DECODE_FAIL \(method) bytes=\(body.count)")
                return http(400, Data())
            }
            if method == "DO_WEB_LOGIN" {
                let user = object["dataObj"]["username"].text
                let pass = object["dataObj"]["password"].text
                let ok = user == "admin" && pass == "test-password"
                loginAccepted = ok
                return json(["result": ok ? "0" : "1"])
            }
            return json(["result": "0"])
        }
        if request.path.hasPrefix("/fh_api/tmp/FHAPIS") || request.path.hasPrefix("/fh_api/tmp/FHNCAPIS") {
            // Mirror the firmware: public endpoints answer before login, protected ones do not.
            let isPublicPath = request.path.hasPrefix("/fh_api/tmp/FHNCAPIS")
            if !isPublicPath && sessionExpired { return http(418, Data("0\n".utf8)) }
            guard isPublicPath || loginAccepted else {
                trace("PROTECTED_PREAUTH \(request.path)")
                return http(403, Data())
            }
            guard let object = decodeEnvelope(body), let method = object["ajaxmethod"].text else {
                return http(400, Data())
            }
            requests.append(method)
            trace("SIGN_OK \(method)")
            if isPublicPath, method != "get_device_info", method != "get_xmlnode_js_file" {
                trace("PUBLIC_PATH_DENIED \(method)")
                return http(403, Data())
            }
            trace("OK \(method)")
            let payload = payload(for: method, request: object["dataObj"])
            guard let key = try? key(), let plain = try? JSONEncoder().encode(payload) else { return http(500, Data()) }
            let cipher = (try? FHCodec.encrypt(plain, key: key)) ?? ""
            return http(200, Data(("AAAAAA" + cipher).utf8))
        }
        return http(404, Data())
    }

    private func payload(for method: String, request: JSONValue) -> JSONValue {
        switch method {
        case "get_device_info":
            return .object(["model_name": .string("LG6851F")])
        case "get_value_by_xmlnode":
            return xmlValues(for: request)
        case "get_xml_childnode_value":
            return childNodes(for: request)
        case "get_sms_data":
            // Mirrors the live reply shape: sessions keyed by `session_item_N`, each with a
            // `session_phone` and `message_item_M` children.
            return .object([
                "session_item_1": .object([
                    "session_phone": .string("10010"),
                    "message_item_2": .object([
                        "childnode": .string("2"), "rcvorsend": .string("recv"),
                        "isOpened": .string("1"), "time": .string("2026/10/09 13:58:55"),
                        "msg_content": .string("第二条：积分提醒")
                    ]),
                    "message_item_1": .object([
                        "childnode": .string("1"), "rcvorsend": .string("recv"),
                        "isOpened": .string("0"), "time": .string("2026/10/09 10:12:00"),
                        "msg_content": .string("合成测试通知 714c：演示套餐剩余 42 GB，仅用于界面与测试。")
                    ])
                ])
            ])
        default:
            return .object(["result": .string("0")])
        }
    }

    /// Echoes back plausible values for every alias the client asked for.
    private func xmlValues(for request: JSONValue) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (alias, path) in request.objectPairs {
            result[alias] = .string(value(for: path.text ?? ""))
        }
        return .object(result)
    }

    private func value(for path: String) -> String {
        let key = path.components(separatedBy: ".").last ?? path
        switch key {
        case "ModelName": return "LG6851F"
        case "SoftwareVersion": return "RP0112"
        case "UpTime", "Total_Uptime": return "18460"
        case "WorkMode": return "SA"
        case "Signal_Level": return "4"
        case "SSB_RSRP": return "-83"
        case "SSB_RSRQ": return "-12"
        case "SSB_SINR": return "7"
        case "NR_Band": return "78"
        case "NR_PCI": return "101"
        case "NCGI": return "70000000001"
        case "TAC": return "42"
        case "PLMN": return "46001"
        case "EARFCN_NBR": return "634464,634464,634464,634464"
        case "RSRP": return "0"
        case "RSRQ": return "0"
        case "SINR": return "0"
        case "BAND": return ""
        case "PCI": return "85"
        case "TodayTotalBytes": return "9420000000"
        case "MonthTotalBytes": return "126800000000"
        case "TodayTotalRxBytes": return "8000000000"
        // Live throughput fields, bytes per second.
        case "SpeedRxBytes": return "1250000"      // 10 Mbps in bytes/s
        case "SpeedTxBytes": return "250000"       // 2 Mbps in bytes/s
        case "TodayTotalTxBytes": return "1420000000"
        case "CarrierName": return "UNICOM"
        case "plmn": return "46001"
        case "NetworkMode": return "3"
        // The live unit reports 0/0 while the uplink is fully usable; these flags are not
        // evidence of availability.
        case "SIMStatus": return "0"
        case "RegisterStatus": return "0"
        case "Modem5GTemperature": return "31708"
        case "Modem4GTemperature": return "44"
        case "mode": return "0"
        case "LockBandEnable": return "0"
        case "LockEnable": return "0"
        case "X_FH_CurrentWANDevice": return "InternetGatewayDevice.WANDevice.1."
        case "ConnectionStatus": return path.contains("WANDevice.2.") ? "Unconfigured" : "Connected"
        case "ExternalIPAddress": return path.contains("WANDevice.2.") ? "" : "198.51.100.20"
        case "Uptime": return "24117"
        case "SMSRecvNumberOfEntries": return "26"
        case "Manufacturer": return "FiberHome"
        case "HardwareVersion": return "WKE2.094.410A01"
        case "NR_CQI": return "12"
        case "NR_Power": return "-1"
        case "NR_QCI": return "8"
        case "DL_AMBR": return "512000"
        case "UL_AMBR": return "102400"
        case "PCI_NBR": return "101,102,103"
        case "BAND_NBR": return "N78,N78,N78"
        case "RSRP_NBR": return "-83,-89,-97"
        case "SINR_NBR": return "7,1,-8"
        default: return ""
        }
    }

    private func childNodes(for request: JSONValue) -> JSONValue {
        let url = request["url"].text ?? ""
        let nodes = Array(request["node"].objectPairs.keys)
        if url.contains("Hosts.Host") {
            let hosts: [[String: String]] = [
                ["name": "Demo-Device-97319e", "devName": "", "mac": "08:9D:F4:E4:70:6E",
                 "ip": "", "active": "0", "interface": "InternetGatewayDevice.LANDevice.1.WLANConfiguration.5",
                 "type": "", "online": "0"],
                ["name": "iPad", "devName": "", "mac": "AA:00:00:00:00:03",
                 "ip": "192.168.8.111", "active": "1", "interface": "InternetGatewayDevice.LANDevice.1.WLANConfiguration.5",
                 "type": "Phone", "online": "64533"],
                ["name": "Demo-Device-2841e0", "devName": "Demo-Device-7c09e0", "mac": "B0:4A:39:79:1B:1E",
                 "ip": "192.168.8.100", "active": "1", "interface": "InternetGatewayDevice.LANDevice.1.WLANConfiguration.1",
                 "type": "Phone", "online": "70405"],
                ["name": "unknown", "devName": "", "mac": "AA:00:00:00:00:04",
                 "ip": "", "active": "0", "interface": "InternetGatewayDevice.LANDevice.1.LANEthernetInterfaceConfig.2",
                 "type": "", "online": "0"],
                ["name": "Demo-Device-922add", "devName": "Demo-Device-495f4d", "mac": "58:47:CA:74:42:0B",
                 "ip": "192.168.8.107", "active": "1", "interface": "InternetGatewayDevice.LANDevice.1.LANEthernetInterfaceConfig.2",
                 "type": "", "online": "60106"]
            ]
            let rows = hosts.map { host in
                JSONValue.object(Dictionary(uniqueKeysWithValues: nodes.map { ($0, .string(host[$0] ?? "")) }))
            }
            return .object(["data": .array(rows)])
        }
        if url.contains("WLANConfiguration") {
            // The live firmware returns empty strings for OperatingFrequencyBand/SSID.
            let rows = (1...8).map { _ in
                JSONValue.object(Dictionary(uniqueKeysWithValues: nodes.map { ($0, .string("")) }))
            }
            return .object(["data": .array(rows)])
        }
        return .object(["data": .array([])])
    }

    // MARK: Crypto

    private func key() throws -> String {
        do { return try FHCodec.deriveKey(token: sessionID, seed: seed) }
        catch {
            trace("KEY_DERIVE_FAIL sid=\(sessionID.count)")
            throw error
        }
    }

    private func decodeEnvelope(_ body: Data) -> JSONValue? {
        guard let wire = String(data: body, encoding: .utf8), wire.count > 6,
              let key = try? key(),
              let plain = try? FHCodec.decrypt(String(wire.dropFirst(6)), key: key) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: plain)
    }

    /// The client rejects a seed that is not exactly 5 bytes, and decrypts with the
    /// firmware private key bundled in FHCPECore. We encrypt with the derived public key.
    private func encryptSeed() -> String {
        guard let der = FHCodec.protocolKeyDER() else { return "" }
        let attrs = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(der as CFData, attrs, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let cipher = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, Data(seed.utf8) as CFData, &error) as Data?
        else { return "" }
        return cipher.base64EncodedString()
    }

    // MARK: Responses

    private func json(_ object: [String: String]) -> Data {
        let data = try? JSONSerialization.data(withJSONObject: object)
        return http(200, data ?? Data(), contentType: "application/json")
    }

    private func http(_ status: Int, _ body: Data, contentType: String = "text/plain") -> Data {
        var header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }
}

extension JSONValue {
    var objectPairs: [String: JSONValue] {
        if case .object(let value) = self { return value }
        return [:]
    }
}

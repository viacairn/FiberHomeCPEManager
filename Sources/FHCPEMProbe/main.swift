import Foundation
import FHCPECore

/// Development-only probe: signs in and reads arbitrary firmware nodes.
///
///     CPE_PASS=… swift run FiberHomeCPEManagerProbe            # built-in candidate list
///     CPE_PASS=… swift run FiberHomeCPEManagerProbe Path.One Path.Two
@main
struct Probe {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let host = env["CPE_HOST"] ?? "192.168.8.1"
        let user = env["CPE_USER"] ?? "admin"
        let password = env["CPE_PASS"] ?? ""
        guard !password.isEmpty else {
            print("CPE_PASS is required")
            exit(1)
        }
        guard let address = try? DeviceAddress(host) else {
            print("bad host: \(host)")
            exit(1)
        }

        if CommandLine.arguments.contains("--session-audit") {
            await auditSessions(address: address, username: user, password: password)
            return
        }
        if CommandLine.arguments.contains("--dhcp-write-audit") {
            let ok = await auditDHCP(address: address, username: user, password: password)
            exit(ok ? 0 : 1)
        }
        let session = DeviceSession(address: address)
        do {
            _ = try await session.connect(username: user, password: password)
        } catch {
            print("login failed: \(error)")
            exit(1)
        }

        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "--keepalive-audit" {
            let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 360
            guard seconds.isFinite, seconds > 0 else {
                print("audit duration must be a positive number of seconds")
                await session.close()
                exit(1)
            }
            let ok = await auditKeepAlive(session, seconds: seconds)
            await session.close()
            exit(ok ? 0 : 1)
        }

        if arguments.first == "--network-audit" {
            let ok = await auditNetwork(session)
            await session.close()
            exit(ok ? 0 : 1)
        }
        if arguments.first == "--fan-audit" {
            let ok = await auditFan(session)
            await session.close()
            exit(ok ? 0 : 1)
        }
        if arguments.first == "--port-add-test" {
            await portAddTest(session)
            await session.close()
            exit(0)
        }
        if arguments.first == "--ddns-add-test" {
            await ddnsAddTest(session)
            await session.close()
            exit(0)
        }
        if arguments.first == "--mobile-test" {
            await mobileTest(session)
            await session.close()
            exit(0)
        }

        // `--sms-list` prints conversations; `--sms-send NUMBER BODY` sends one message and
        // re-lists after a short wait, which is how outbound + inbox sync are verified
        // without driving the UI.
        if arguments.first == "--sms-list" {
            await printThreads(session)
            await session.close()
            exit(0)
        }
        if arguments.first == "--sms-send", arguments.count >= 3 {
            let number = arguments[1], body = arguments[2]
            do {
                _ = try await session.sendSMS(to: number, body: body)
                print("send result: success")
            } catch {
                print("send result: failure \(error)")
            }
            try? await Task.sleep(for: .seconds(2))
            await printThreads(session)
            await session.close()
            exit(0)
        }

        // `--uplink <mode>` runs the production switch path end to end.
        if let index = arguments.firstIndex(of: "--uplink"), arguments.count > index + 1 {
            let name = arguments[index + 1]
            guard let target = UplinkTarget(rawValue: name) else {
                print("unknown mode: \(name); use \(UplinkTarget.allCases.map(\.rawValue))")
                exit(1)
            }
            do {
                let applied = try await session.setUplink(target)
                print("setUplink(\(target.rawValue)) -> \(applied)")
            } catch {
                print("switch failed: \(error)")
            }
            if let settings = try? await session.readSettings() {
                print("readback: device=\(settings.currentWANDevice) aggregation=\(settings.aggregationEnabled) active=\(settings.activeUplink.rawValue)")
            }
            await session.close()
            exit(0)
        }

        // `--set path value` writes one node and reads it back; used to verify a write path
        // before wiring it into the UI.
        if let setIndex = arguments.firstIndex(of: "--set"), arguments.count > setIndex + 2 {
            let path = arguments[setIndex + 1]
            let value = arguments[setIndex + 2]
            do {
                let reply = try await session.writeProbe(path, value: value)
                print("raw reply: \(reply)")
            } catch {
                print("write failed: \(error)")
            }
            await session.close()
            exit(0)
        }
        let paths = arguments.isEmpty ? Candidates.all : arguments
        var fields: [String: String] = [:]
        for (index, path) in paths.enumerated() {
            fields["p\(index)"] = path
        }
        do {
            let value = try await session.probe(fields)
            for (index, path) in paths.enumerated() {
                let text = value["p\(index)"].text
                if let text, !text.isEmpty {
                    print("\(path) = \(text)")
                }
            }
        } catch {
            print("read failed: \(error)")
        }
        await session.close()
    }

    /// Exercises the production session without UI activity or automatic re-login.
    /// Output contains only elapsed time and counts, never device readings or identity.
    static func auditKeepAlive(_ session: DeviceSession, seconds: Double) async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .seconds(seconds))
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var sampledAt = started
        var count = 1 // connect already obtained the first protected sample
        var lastReport = 0
        func report(_ text: String) {
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }
        report("idle session audit: duration=\(Int(seconds))s, refresh=\(Int(SessionRefreshPolicy.dataInterval))s")
        do {
            while clock.now < deadline {
                try await clock.sleep(until: min(sampledAt.advanced(by: .seconds(SessionRefreshPolicy.dataInterval)), deadline))
                sampledAt = clock.now
                _ = try await session.refresh()
                count += 1
                let elapsed = Int(ProcessInfo.processInfo.systemUptime - startedUptime)
                if elapsed - lastReport >= 30 {
                    report("elapsed=\(elapsed)s, protected samples=\(count), authenticated")
                    lastReport = elapsed
                }
            }
            report("PASS: idle for \(Int(ProcessInfo.processInfo.systemUptime - startedUptime))s; \(count) protected samples; no re-login")
            return true
        } catch {
            let elapsed = Int(ProcessInfo.processInfo.systemUptime - startedUptime)
            report("FAIL: elapsed=\(elapsed)s; \(error.localizedDescription)")
            return false
        }
    }

    /// Explicit development diagnostic. Uses two independent in-memory cookie jars,
    /// reads only, and prints no credentials, cookies, tokens, or message contents.
    static func auditSessions(address: DeviceAddress, username: String, password: String) async {
        let first = LocalTransport(address: address), second = LocalTransport(address: address)
        do {
            try await LG6851Adapter(rpc: first).login(username: username, password: password)
            _ = try await first.call("get_sms_data", data: .null, publicAccess: false)
            print("entry A: login and SMS read succeeded")
            try await LG6851Adapter(rpc: second).login(username: username, password: password)
            print("entry B: login succeeded")
            if CommandLine.arguments.contains("--session-audit-wait") {
                print("ready for browser login")
                _ = readLine()
            }
            for method in ["get_sms_data", "get_value_by_xmlnode"] {
                do {
                    let data: JSONValue = method == "get_sms_data" ? .null : .strings(["model": "DeviceInfo.ModelName"])
                    _ = try await first.call(method, data: data, publicAccess: false)
                    print("entry A after B / \(method): still authenticated")
                } catch {
                    print("entry A after B / \(method): \(error)")
                }
            }
        } catch { print("session audit failed: \(error)") }
        await first.close(); await second.close()
    }

    /// Uses an unused locally administered MAC and two unoccupied pool addresses. No
    /// actual client's binding is edited. Cleanup also runs after an uncertain write.
    static func auditDHCP(address: DeviceAddress, username: String, password: String) async -> Bool {
        let transport = LocalTransport(address: address)
        let adapter = LG6851Adapter(rpc: transport)
        let service = DHCPReservationService(rpc: transport)
        var baseline: [DHCPReservation]?
        var ownedMAC: String?
        var testIPs = Set<String>()
        var ok = true
        do {
            try await adapter.login(username: username, password: password)
            let original = try await service.read()
            baseline = original
            let clients = try await adapter.devices()
            let config = try await adapter.read([
                "min": DHCPReservationService.lanRoot + "MinAddress",
                "max": DHCPReservationService.lanRoot + "MaxAddress",
                "router": DHCPReservationService.lanRoot + "IPInterface.1.IPInterfaceIPAddress"
            ])
            func number(_ text: String?) -> UInt32? {
                guard let text else { return nil }
                let parts = text.split(separator: ".")
                guard parts.count == 4 else { return nil }
                var value: UInt32 = 0
                for part in parts {
                    guard let octet = UInt8(part) else { return nil }
                    value = (value << 8) | UInt32(octet)
                }
                return value
            }
            func addressText(_ value: UInt32) -> String {
                [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
            }
            guard let min = number(config["min"].text), let max = number(config["max"].text),
                  min < max, max - min < 65_536 else { throw CPEError.malformedResponse }
            let occupied = Set(original.map(\.ip) + clients.map(\.ip) + [config["router"].text ?? ""])
            var free: [String] = []
            for candidate in stride(from: Int(max), through: Int(min), by: -1) {
                let ip = addressText(UInt32(candidate))
                if !occupied.contains(ip) { free.append(ip) }
                if free.count == 2 { break }
            }
            guard free.count == 2 else { throw CPEError.unsupported("DHCP 地址池没有两个空闲测试地址") }
            let bytes = Array(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
            let tail = stride(from: 0, to: bytes.count, by: 2).map { String(bytes[$0...($0 + 1)]) }
            let mac = (["02", "CF"] + tail).joined(separator: ":").uppercased()
            guard !Set(original.map(\.mac) + clients.compactMap(\.mac).map { $0.uppercased() }).contains(mac) else {
                throw CPEError.uncertain
            }
            ownedMAC = mac; testIPs = Set(free)
            print("DHCP table read: confirmed")
            _ = try await service.reserve(mac: mac, ip: free[0])
            print("DHCP create and independent read-back: confirmed")
            _ = try await service.reserve(mac: mac, ip: free[1])
            print("DHCP edit and independent read-back: confirmed")
        } catch {
            ok = false
            print("DHCP audit: \(error.localizedDescription)")
        }
        if let ownedMAC {
            do {
                if let current = try await service.read().first(where: { $0.mac == ownedMAC }) {
                    guard testIPs.contains(current.ip) else { throw CPEError.uncertain }
                    try await service.remove(current)
                }
                let remaining = try await service.read()
                let before = Set((baseline ?? []).map { "\($0.mac)|\($0.ip)" })
                let after = Set(remaining.map { "\($0.mac)|\($0.ip)" })
                guard before == after else { throw CPEError.uncertain }
                print("DHCP cleanup and original table: confirmed")
            } catch {
                ok = false
                print("DHCP cleanup needs attention for test MAC \(ownedMAC): \(error.localizedDescription)")
            }
        }
        await transport.close()
        return ok
    }

    /// Read-only snapshot of the nodes added for the mobile/DDNS/port-mapping pages.
    static func auditNetwork(_ session: DeviceSession) async -> Bool {
        do {
            let mobile = try await session.readMobileNetwork()
            print("mobile: airplane=\(mobile.airplaneMode) data=\(mobile.cellularDataEnabled) "
                + "antenna=\(mobile.antennaEnabled) type=\(mobile.antennaType?.title ?? "-") "
                + "wan=\(mobile.cellularWAN?.title ?? "-")")
            let ddns = try await session.readDDNS()
            print("ddns: \(ddns.count)")
            let ports = try await session.readPortMappings()
            print("port mappings: \(ports.count)")
            return true
        } catch {
            print("network audit failed: \(error)")
            return false
        }
    }

    /// Explicit device write check; every successful save includes a protected read-back.
    /// Restore the confirmed initial mode even when an intermediate verification fails.
    static func auditFan(_ session: DeviceSession) async -> Bool {
        let initial: FanMode
        do {
            guard let mode = try await session.readSettings().fan else {
                print("unknown initial fan mode; no write sent"); return false
            }
            initial = mode
        } catch {
            print("fan precheck failed; no write sent: \(error.localizedDescription)"); return false
        }
        var success = true
        do {
            for mode in FanMode.allCases {
                guard try await session.setFanMode(mode) else { throw CPEError.uncertain }
                print("fan mode \(mode.rawValue): confirmed")
            }
        } catch {
            success = false
            print("fan audit failed: \(error.localizedDescription)")
        }
        do {
            guard try await session.setFanMode(initial) else { throw CPEError.uncertain }
            print("fan restored to initial mode \(initial.rawValue)")
        } catch {
            print("fan restoration FAILED: \(error.localizedDescription)")
            return false
        }
        return success
    }

    /// Adds one disabled mapping, reads it back, then deletes it. Used only by explicit
    /// manual verification; never part of the normal test suite.
    static func portAddTest(_ session: DeviceSession) async {
        do {
            let mobile = try await session.readMobileNetwork()
            guard let wan = mobile.cellularWAN else { print("no cellular WAN"); return }
            let input = PortMappingInput(wan: wan, localIP: "198.51.100.23",
                                         internalPort: 59999, internalEnd: 59999,
                                         externalPort: 59999, externalEnd: 59999,
                                         proto: .tcp, enabled: false)
            let entry = try await session.addPortMapping(input)
            print("added port mapping: \(entry.id) \(entry.localIP) \(entry.internalRange)")
            try await session.deletePortMapping(entry)
            print("deleted port mapping: \(entry.id)")
            print("remaining: \(try await session.readPortMappings().count)")
        } catch {
            print("port add test failed: \(error)")
        }
    }

    /// Re-writes the current airplane/data values (no state change), toggles the external
    /// antenna off and back on, and reads the state after each step.
    static func mobileTest(_ session: DeviceSession) async {
        do {
            let before = try await session.readMobileNetwork()
            print("before: airplane=\(before.airplaneMode) data=\(before.cellularDataEnabled) "
                + "antenna=\(before.antennaEnabled) type=\(before.antennaType?.title ?? "-")")
            _ = try await session.setAirplaneMode(before.airplaneMode)
            print("airplane same-value write: ok")
            _ = try await session.setCellularData(before.cellularDataEnabled)
            print("cellular same-value write: ok")
            let type = before.antennaType ?? .automatic
            let toggled = try await session.setAntenna(enabled: !before.antennaEnabled, type: type)
            print("antenna toggled: \(toggled.antennaEnabled)")
            _ = try await session.setAntenna(enabled: before.antennaEnabled, type: type)
            let after = try await session.readMobileNetwork()
            print("after: airplane=\(after.airplaneMode) data=\(after.cellularDataEnabled) "
                + "antenna=\(after.antennaEnabled) type=\(after.antennaType?.title ?? "-")")
        } catch {
            print("mobile test failed: \(error)")
        }
    }

    /// Adds one disabled DDNS entry, reads it back, then deletes it.
    static func ddnsAddTest(_ session: DeviceSession) async {
        do {
            let mobile = try await session.readMobileNetwork()
            guard let wan = mobile.cellularWAN else { print("no cellular WAN"); return }
            let input = DDNSInput(wan: wan, provider: "dyndns", hostname: "fhcpem-test.invalid",
                                  username: "fhcpem", password: "test-only", enabled: false)
            let entry = try await session.addDDNS(input)
            print("added ddns: \(entry.id) \(entry.hostname) enabled=\(entry.enabled)")
            try await session.deleteDDNS(entry)
            print("deleted ddns: \(entry.id)")
            print("remaining: \(try await session.readDDNS().count)")
        } catch {
            print("ddns add test failed: \(error)")
        }
    }
}

private func printThreads(_ session: DeviceSession) async {
    do {
        let threads = try await session.threads()
        print("threads: \(threads.count)")
        for thread in threads {
            print("  \(thread.phone): \(thread.messages.count) messages")
            for message in thread.messages.suffix(4) {
                print("    [\(message.isSent ? "sent" : "recv")] \(message.date) \(message.body.prefix(50))")
            }
        }
    } catch {
        print("sms read failed: \(error)")
    }
}

enum Candidates {
    static let all: [String] = [
        "DeviceInfo.X_FH_CurrentWANDevice",
        "DeviceInfo.X_FH_Multiwan_Aggregation.Enable",
        "DeviceInfo.X_FH_Multiwan_Mode",
        "DeviceInfo.X_FH_Multiwan_Policy",
        "DeviceInfo.X_FH_WANMode",
        "DeviceInfo.WANMode",
        "X_FH_MobileNetwork.RadioSignalParameter.WorkMode",
        "X_FH_MobileNetwork.RadioSignalParameter.CA",
        "X_FH_MobileNetwork.RadioSignalParameter.CA_State",
        "X_FH_MobileNetwork.RadioSignalParameter.CarrierAggregation",
        "X_FH_MobileNetwork.RadioSignalParameter.SCC",
        "X_FH_MobileNetwork.RadioSignalParameter.SCC_Num",
        "X_FH_MobileNetwork.RadioSignalParameter.NR_CA",
        "X_FH_MobileNetwork.RadioSignalParameter.NR_SCC",
        "X_FH_MobileNetwork.RadioSignalParameter.PCC_BAND",
        "X_FH_MobileNetwork.RadioSignalParameter.SCC1_BAND",
        "X_FH_MobileNetwork.RadioSignalParameter.CA_BAND",
        "X_FH_MobileNetwork.RadioSignalParameter.NR_Band",
        "X_FH_MobileNetwork.RadioSignalParameter.BAND",
        "X_FH_MobileNetwork.NetworkSettings.WorkMode",
        "X_FH_MobileNetwork.NetworkSettings.CarrierAggregation",
        "InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANIPConnection.1.ConnectionType",
        "InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANIPConnection.1.Name",
        "InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANIPConnection.1.ExternalIPAddress",
        "InternetGatewayDevice.DeviceInfo.X_FH_CurrentWANDevice"
    ]
}

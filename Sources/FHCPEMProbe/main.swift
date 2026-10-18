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

        let session = DeviceSession(address: address)
        do {
            _ = try await session.connect(username: user, password: password)
        } catch {
            print("login failed: \(error)")
            exit(1)
        }

        let arguments = Array(CommandLine.arguments.dropFirst())

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

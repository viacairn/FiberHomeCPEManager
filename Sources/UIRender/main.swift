import AppKit
import SwiftUI
import FHCPECore
import FHCPEMUI

/// Development-only renderer. It mounts the real SwiftUI shells offscreen and writes PNGs
/// so layout can be inspected without Screen Recording permission and without touching a
/// live device session. Not part of the shipped app bundle.
@main
struct UIRender {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        let outDir = args.count > 1 ? args[1] : "./render"
        let dark = args.contains("--dark")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let renderer = Renderer(outputDirectory: outDir, dark: dark)
        renderer.renderAll()
        print("wrote \(renderer.written.count) images to \(outDir)")
        for path in renderer.written { print(path) }
    }
}

@MainActor
final class Renderer {
    let outputDirectory: String
    let dark: Bool
    var written: [String] = []

    init(outputDirectory: String, dark: Bool) {
        self.outputDirectory = outputDirectory
        self.dark = dark
    }

    func renderAll() {
        let fixtures = Fixtures()
        render("01-overview-light", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.connected(tab: 0))
        }
        render("02-devices", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.connected(tab: 1))
        }
        render("03-devices-filtered", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 1)
            model.searchQuery = "i"
            model.accessFilter = .wifi5G
            return ShellView(model: model)
        }
        render("04-controls", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.connected(tab: 2))
        }
        render("05-sms-inbox", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.connected(tab: 3))
        }
        render("06-sms-compose", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 3)
            model.selectedThreadID = "10010"
            model.smsRoute = .thread
            return ShellView(model: model)
        }
        render("07-sms-new-chat", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 3)
            model.selectedThreadID = nil
            model.smsRoute = .thread
            return ShellView(model: model)
        }
        render("08-connect", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.firstRun())
        }
        render("09-cellular", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 0)
            model.route = .cellular
            return ShellView(model: model)
        }
        render("11-cellular-cells", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 0)
            model.route = .cellular
            model.cellularTab = 1
            return ShellView(model: model)
        }
        render("10-offline", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.offline())
        }
        render("12-controls-error", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 2)
            model.settingsStatus = "操作失败：设备返回 400（set_single_by_xmlnode 被拒绝）"
            model.settingsStatusIsError = true
            return ShellView(model: model)
        }
        render("13-sms-error", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 3)
            model.smsStatus = "短信读取失败：请求超时"
            model.smsStatusIsError = true
            return ShellView(model: model)
        }
        render("14-overview-ethernet-nocard", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.ethernetNoSim())
        }
    }

    func render(_ name: String, width: CGFloat, height: CGFloat, @ViewBuilder body: () -> some View) {
        let root = body()
            .frame(width: width, height: height)
            .background(dark ? Color.black : Color.white)
        let hosting = NSHostingView(rootView: ForcedAppearance(content: root, dark: dark))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its layout and any material/gradient passes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // `cacheDisplay` runs in the view's own coordinate space, which keeps text
        // upright; `layer.render(in:)` would double-apply the non-flipped NSView origin.
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        hosting.cacheDisplay(in: bounds, to: rep)
        let path = (outputDirectory as NSString).appendingPathComponent("\(name).png")
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            written.append(path)
        }
        window.orderOut(nil)
    }
}

private struct ForcedAppearance<Content: View>: View {
    let content: Content
    let dark: Bool
    var body: some View {
        content
            .preferredColorScheme(dark ? .dark : .light)
            .environment(\.fhcpemGlassEnabled, false)
    }
}

// MARK: - Fixtures

@MainActor
struct Fixtures {
    func snapshot() -> DeviceSnapshot {
        var s = DeviceSnapshot()
        s.model = "LG6851F"
        s.firmware = "RP0112"
        s.network = "5G"
        s.activeTech = .nr
        s.nrMode = "SA"
        s.manufacturer = "FiberHome"
        s.operatorName = "Unicom"
        s.smsCount = 28
        s.uptime = "18460"
        s.wanConnected = true
        s.ethernetConnected = false
        s.ethernetAddress = nil
        s.wanAddress = "198.51.100.21"
        s.uplinkEvidence = "蜂窝已连接 · 以太网未接入"
        s.temperature = "31.7"
        s.plmn = "46001"
        s.uplink = .cellular
        s.uplinkAvailable = true
        s.signalBars = 4
        s.nr.rsrp = "-83"
        s.nr.qci = "8"
        s.nr.cqi = "12"
        s.nr.power = "-1"
        s.nr.dlAmbrKbps = 512000
        s.nr.ulAmbrKbps = 102400
        s.nr.rsrq = "-12"
        s.nr.sinr = "7"
        s.nr.band = "n78"
        s.nr.pci = "101"
        s.nr.cell = "70000000001"
        s.nr.tac = "42"
        s.nr.plmn = "46001"
        s.nr.arfcn = "634464"
        s.downloadBps = 102_400_000
        s.uploadBps = 12_800_000
        s.todayBytes = 9_420_000_000
        s.monthBytes = 126_800_000_000
        s.devicesKnown = true
        s.deviceCount = 9
        return s
    }

    func devices() -> [ConnectedDevice] {
        [
            .init(id: "1", name: "MacBook Pro", ip: "192.168.8.101", access: .wired, deviceType: "laptop"),
            .init(id: "2", name: "iPhone", ip: "192.168.8.102", access: .wifi5G, deviceType: "phone"),
            .init(id: "3", name: "Demo-Device-b42402", ip: "192.168.8.103", access: .wifi24G, hostname: "Demo-Device-2841e0"),
            .init(id: "4", name: "客厅电视", ip: "192.168.8.104", access: .wired, deviceType: "tv"),
            .init(id: "5", name: "Demo-Device-ecbea2", ip: "192.168.8.105", access: .wifi24G, deviceType: "game"),
            .init(id: "6", name: "MacBook Air", ip: "192.168.8.109", access: .wifi5G, deviceType: "laptop"),
            .init(id: "7", name: "客厅平板", ip: "192.168.8.110", access: .wifi5G, deviceType: "tablet"),
            .init(id: "8", name: "Demo-Device-43d125", ip: "192.168.8.111", access: .wired, deviceType: "desktop"),
            .init(id: "9", name: "Demo-Device-b98d85", ip: "192.168.8.112", access: .wifi24G)
        ]
    }

    func cells() -> [CellRecord] {
        [
            .init(tech: .nr, band: "N78", pci: "101", channel: "634464", rsrp: "-83", sinr: "7", state: .serving),
            .init(tech: .nr, band: "N78", pci: "102", channel: "634464", rsrp: "-89", sinr: "1", state: .neighbor),
            .init(tech: .nr, band: "N78", pci: "103", channel: "634464", rsrp: "-97", sinr: "-8", state: .neighbor)
        ]
    }

    func settings() -> DeviceSettings {
        var s = DeviceSettings()
        s.currentWANDevice = UplinkTarget.cellularDevice
        s.aggregationEnabled = false
        s.wifi = [
            .init(id: 1, ssid: "FHCPEM-DEMO-2G", enabled: true, band: "2.4G", security: "WPA2-PSK"),
            .init(id: 2, ssid: "FHCPEM-DEMO-WIFI", enabled: false, band: "2.4G", security: "WPA2-PSK"),
            .init(id: 5, ssid: "FHCPEM-DEMO-5G", enabled: true, band: "5G", security: "WPA3-SAE"),
            .init(id: 6, ssid: "FHCPEM-DEMO-5G", enabled: false, band: "5G", security: "WPA2-PSK")
        ]
        s.rebootEnabled = true
        s.rebootTime = "04:30"
        s.rebootWeekday = "Sunday"
        s.ledOn = true
        s.fanMode = "2"
        s.mloGroups = 0
        return s
    }

    func threads() -> [SMSThread] {
        [
            SMSThread(phone: "10010", messages: [
                .init(id: "1", sender: "10010", body: "合成测试通知 32fc：演示套餐剩余 42 GB，仅用于界面与测试。", date: "2026/10/09 10:12:00", isRead: true),
                .init(id: "send-1", sender: "10010", body: "流量查询", date: "2026/10/09 13:58:10", isRead: true, isSent: true, childnode: "1"),
                .init(id: "2", sender: "10010", body: "合成测试通知 2a90：演示套餐剩余 42 GB，仅用于界面与测试。", date: "2026/10/09 13:58:55", isRead: false)
            ]),
            SMSThread(phone: "服务通知", messages: [
                .init(id: "3", sender: "服务通知", body: "您的设备已完成固件升级。", date: "2026/10/08 09:00:00", isRead: true)
            ])
        ]
    }

    func connected(tab: Int) -> ShellModel {
        let model = ShellModel(route: .main, tab: tab,
                               data: PageData(snapshot: snapshot(), devices: devices(), stale: false, connected: true),
                               devices: devices(), cells: cells(), lockMode: .automatic)
        model.settings = settings()
        model.threads = threads()
        model.smsLastSync = Date()
        return model
    }

    func ethernetNoSim() -> ShellModel {
        var s = DeviceSnapshot()
        s.model = "LG6851F"
        s.firmware = "RP0112"
        s.network = ""
        s.activeTech = .unknown
        s.manufacturer = "FiberHome"
        s.uptime = "86400"
        s.wanConnected = false
        s.ethernetConnected = true
        s.ethernetAddress = "192.168.1.58"
        s.wanAddress = nil
        s.uplink = .broadband
        s.uplinkAvailable = true
        s.signalBars = nil
        s.temperature = "29.4"
        s.downloadBps = 245_000_000
        s.uploadBps = 38_000_000
        s.todayBytes = 4_200_000_000
        s.monthBytes = 58_000_000_000
        s.devicesKnown = true
        s.deviceCount = 9
        return ShellModel(route: .main, tab: 0,
                          data: PageData(snapshot: s, devices: devices(), stale: false, connected: true),
                          devices: devices(), cells: [], lockMode: .automatic)
    }

    func offline() -> ShellModel {
        ShellModel(route: .main, tab: 0, data: PageData(snapshot: nil, devices: [], stale: true, connected: false))
    }

    func firstRun() -> ShellModel {
        ShellModel(route: .connect)
    }
}

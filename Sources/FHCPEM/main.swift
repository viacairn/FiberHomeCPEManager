import SwiftUI
import AppKit
import FHCPECore

@MainActor @Observable final class AppStore {
    var address = "http://192.168.8.1"
    var username = "admin"
    var password = ""
    var remember = false
    var busy = false
    var connected = false
    var visibleViews: Set<UUID> = []
    var stale = false
    var status = "连接你的 FiberHome CPE"
    var snapshot: DeviceSnapshot?
    var tab = 0
    var menuStyle = 0
    private var session: DeviceSession?
    private var refreshTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var generation = UUID()
    private let keychain = CredentialStore()
    init() {
        do { if let saved = try keychain.load() { address = saved.address; username = saved.username; password = saved.password; remember = true } }
        catch { status = error.localizedDescription }
    }
    func connect() {
        guard !busy else { return }
        let id = UUID(); generation = id; refreshTask?.cancel(); connectionTask?.cancel(); busy = true; connected = false
        let previous = session; session = nil; snapshot = nil
        let credentials = Credentials(address: address, username: username, password: password)
        connectionTask = Task {
            await previous?.close()
            guard generation == id, !Task.isCancelled else { return }
            do {
                let next = DeviceSession(address: try DeviceAddress(credentials.address)); session = next
                let value = try await next.connect(username: credentials.username, password: credentials.password)
                guard generation == id, !Task.isCancelled else { await next.close(); return }
                stale = false; snapshot = value; connected = true; status = "已连接 · 数据仅驻留内存"
                do { if remember { try keychain.save(credentials) } else { try keychain.delete() } }
                catch { status = "已连接，但钥匙串操作失败：\(error.localizedDescription)" }
                password = ""; busy = false; startRefresh()
            } catch { guard generation == id else { return }; busy = false; status = error.localizedDescription }
        }
    }
    func disconnect() {
        generation = UUID(); connectionTask?.cancel(); connectionTask = nil; refreshTask?.cancel(); refreshTask = nil
        let previous = session; session = nil; connected = false; busy = false; snapshot = nil; password = ""; status = "已断开"
        Task { await previous?.close() }
    }
    func forget() { do { try keychain.delete(); remember = false; password = ""; status = "已删除钥匙串中的连接信息" } catch { status = error.localizedDescription } }
    func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: .seconds(visibleViews.isEmpty ? 15 : 5))
            }
        }
    }
    func refresh() async {
        guard !busy, connected, let session else { return }
        busy = true; let id = generation
        defer { if id == generation { busy = false } }
        do { let value = try await session.refresh(); guard id == generation else { return }; stale = false; snapshot = value; status = "已连接 · 数据仅驻留内存" }
        catch {
            guard id == generation, !Task.isCancelled else { return }
            stale = true
            status = "刷新失败，保留上次数据：\(error.localizedDescription)"
            if case CPEError.authentication = error {
                connected = false; refreshTask?.cancel()
                status = "登录已失效，请重新连接。以下为上次数据。"
                await session.close()
            }
        }
    }
    var menuText: String {
        guard let s = snapshot else { return "" }
        if stale { return "离线" }
        if menuStyle == 1 { return s.nr.rsrp.map { "\($0) dBm" } ?? "—" }
        if menuStyle == 2 { return "↓ " + bytes(s.download) + "/s" }
        return ""
    }
    func bytes(_ value: Double?) -> String { guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }; return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .decimal) }
}

@main struct FHCPEMApp: App {
    @State private var store = AppStore()
    var body: some Scene {
        MenuBarExtra { Dashboard(store: store) } label: { Label(store.menuText, systemImage: "antenna.radiowaves.left.and.right") }.menuBarExtraStyle(.window)
        Window("FHCPEM", id: "main") { Dashboard(store: store) }.defaultSize(width: 440, height: 620).windowResizability(.contentSize)
    }
}

struct Dashboard: View {
    @Bindable var store: AppStore
    @State private var settings = false
    @State private var viewID = UUID()
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading) { Text("FHCPEM").font(.title2.bold()); Text(store.snapshot.map { "\($0.model) · \($0.firmware)" } ?? "你的网络，一目了然").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3") }.help("连接设置")
            }
            if !store.connected || settings { connection }
            if let snapshot = store.snapshot {
                Picker("页面", selection: $store.tab) { Text("概览").tag(0); Text("设备").tag(1); Text("控制").tag(2); Text("短信").tag(3) }.pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch store.tab {
                        case 0: overview(snapshot)
                        case 1:
                            Text(snapshot.devicesKnown ? "在线设备 · \(snapshot.devices.count)" : "在线设备 · —").font(.headline)
                            if snapshot.devices.isEmpty { Text("暂无在线设备数据").foregroundStyle(.secondary) }
                            ForEach(snapshot.devices) { device in
                                HStack { Image(systemName: "network"); VStack(alignment: .leading) { Text(device.name); Text(device.ip).font(.caption.monospaced()).foregroundStyle(.secondary) }; Spacer(); Text(device.interface).font(.caption).lineLimit(2) }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            }
                        case 2:
                            Label("控制接口验证中", systemImage: "wrench.and.screwdriver").font(.headline)
                            Text("风扇策略、重启和无线锁定需要确认该固件的请求及回执。当前不发送尚未验证的控制请求。")
                            Text("无线锁定采用单一模式：自动 / 锁频段 / 锁小区；切换时必须先解除并确认旧模式。").foregroundStyle(.secondary)
                        default:
                            Label("短信接口验证中", systemImage: "message").font(.headline)
                            Text("尚未确认此固件的短信读取和发送格式。短信内容不会保存到磁盘。")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 300)
                HStack { Text("更新于 \(snapshot.updated.formatted(date: .omitted, time: .standard))").font(.caption); Spacer(); Button("刷新") { Task { await store.refresh() } }.disabled(store.busy) }.foregroundStyle(.secondary)
            }
            Text(store.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Divider()
            HStack {
                Picker("菜单栏", selection: $store.menuStyle) { Text("仅图标").tag(0); Text("5G 信号").tag(1); Text("下载速率").tag(2) }.labelsHidden().frame(width: 110)
                Spacer()
                Button("独立窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.controlSize(.small)
        }.padding(20).frame(width: 440).background(.regularMaterial)
        .onAppear { store.visibleViews.insert(viewID) }.onDisappear { store.visibleViews.remove(viewID) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in if store.connected { store.startRefresh() } }
    }
    var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接设置").font(.headline)
            TextField("管理地址", text: $store.address).textContentType(.URL)
            HStack { TextField("账号", text: $store.username); SecureField("密码", text: $store.password) }
            Toggle("使用钥匙串记住连接信息", isOn: $store.remember).font(.caption)
            HStack { Button(store.connected ? "重新连接" : "连接") { store.connect() }.buttonStyle(.borderedProminent).disabled(store.busy); if store.connected { Button("断开") { store.disconnect() } }; Spacer(); Button("忘记凭据") { store.forget() } }
        }.textFieldStyle(.roundedBorder).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
    func overview(_ s: DeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label(s.network, systemImage: "cellularbars").font(.headline); Spacer(); Text(s.devicesKnown ? "\(s.devices.count) 台在线" : "设备列表待刷新").foregroundStyle(.secondary) }
            HStack { metric("今日流量", store.bytes(s.todayBytes)); metric("本月流量", store.bytes(s.monthBytes)) }
            HStack { metric("下载 · 采样均速", store.bytes(s.download) + "/s"); metric("上传 · 采样均速", store.bytes(s.upload) + "/s") }
            Text("设备统计周期 · 今日 / 本月").font(.caption).foregroundStyle(.secondary)
            radio("5G NR", s.nr)
            radio("4G LTE", s.lte)
            DisclosureGroup("更多设备信息") { LabeledContent("运行时间", value: s.uptime ?? "—"); LabeledContent("温度原始值", value: s.temperature ?? "—") }.font(.caption)
        }
    }
    func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold().monospacedDigit()) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) }
    func radio(_ title: String, _ r: RadioReading) -> some View {
        GroupBox { VStack(spacing: 8) { HStack { Text("RSRP"); Spacer(); Text(r.rsrp.map { "\($0) dBm" } ?? "—").monospacedDigit() }; HStack { Text("RSRQ / SINR"); Spacer(); Text("\(r.rsrq ?? "—") / \(r.sinr ?? "—") dB").monospacedDigit() }; HStack { Text("频段 / PCI"); Spacer(); Text("\(r.band ?? "—") / \(r.pci ?? "—")") }; DisclosureGroup("小区标识") { Text(r.cell ?? "—").textSelection(.enabled) } }.font(.callout).padding(4) } label: { Text(title).font(.headline) }
    }
}

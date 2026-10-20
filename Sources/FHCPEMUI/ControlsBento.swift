import SwiftUI
import FHCPECore

/// Controls as a single Bento screen: uplink-mode status, Wi-Fi broadcast, a transactional
/// scheduled-reboot card, and hardware tiles.
///
/// The v1 design made each setting a drill-in page — opening "Fan" showed one read-only
/// number on an otherwise empty page. Everything now lives on one screen, with the two
/// settings that need more than a switch (Wi-Fi backup channels, reboot schedule) expanding
/// in place.
public struct ControlsPage: View {
    public let settings: DeviceSettings?
    public let busy: Bool
    public let status: String?
    public let statusIsError: Bool
    public let isLive: Bool
    public let onToggleSSID: (WiFiNetwork, Bool) -> Void
    public let onRenameSSID: (WiFiNetwork, String) -> Void
    public let onSaveReboot: (Bool, String, String) -> Void
    public let onSaveLED: (Bool) -> Void
    public let onSaveFan: (FanMode) -> Void
    public let switchingTo: UplinkTarget?
    public let onSwitchUplink: (UplinkTarget) -> Void
    public let mobile: MobileNetworkState?
    public let onSetAirplaneMode: (Bool) -> Void
    public let onSetCellularData: (Bool) -> Void
    public let onSaveAntenna: (Bool, AntennaType) -> Void
    public let ddnsCount: Int?
    public let portMappingCount: Int?
    public let onOpenDDNS: () -> Void
    public let onOpenPortMapping: () -> Void

    public init(settings: DeviceSettings?, busy: Bool, status: String?,
                statusIsError: Bool = false, isLive: Bool = true,
                onToggleSSID: @escaping (WiFiNetwork, Bool) -> Void,
                onRenameSSID: @escaping (WiFiNetwork, String) -> Void,
                onSaveReboot: @escaping (Bool, String, String) -> Void,
                onSaveLED: @escaping (Bool) -> Void,
                onSaveFan: @escaping (FanMode) -> Void = { _ in },
                switchingTo: UplinkTarget? = nil,
                onSwitchUplink: @escaping (UplinkTarget) -> Void = { _ in },
                mobile: MobileNetworkState? = nil,
                onSetAirplaneMode: @escaping (Bool) -> Void = { _ in },
                onSetCellularData: @escaping (Bool) -> Void = { _ in },
                onSaveAntenna: @escaping (Bool, AntennaType) -> Void = { _, _ in },
                ddnsCount: Int? = nil, portMappingCount: Int? = nil,
                onOpenDDNS: @escaping () -> Void = {},
                onOpenPortMapping: @escaping () -> Void = {}) {
        self.settings = settings; self.busy = busy; self.status = status
        self.statusIsError = statusIsError; self.isLive = isLive
        self.onToggleSSID = onToggleSSID; self.onRenameSSID = onRenameSSID
        self.onSaveReboot = onSaveReboot; self.onSaveLED = onSaveLED; self.onSaveFan = onSaveFan
        self.switchingTo = switchingTo; self.onSwitchUplink = onSwitchUplink
        self.mobile = mobile
        self.onSetAirplaneMode = onSetAirplaneMode; self.onSetCellularData = onSetCellularData
        self.onSaveAntenna = onSaveAntenna
        self.ddnsCount = ddnsCount; self.portMappingCount = portMappingCount
        self.onOpenDDNS = onOpenDDNS; self.onOpenPortMapping = onOpenPortMapping
    }

    @State private var showBackupWiFi = false
    @State private var rebootExpanded = false
    @State private var draftTime = "04:30"
    @State private var draftWeekday = "Everyday"
    @State private var pendingUplink: UplinkTarget?
    @State private var fanMenuOpen = false

    public var body: some View {
        VStack(spacing: 0) {
            if isLive {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        MobileNetworkSection(state: mobile, busy: busy,
                                             onSetAirplane: onSetAirplaneMode,
                                             onSetCellular: onSetCellularData,
                                             onSaveAntenna: onSaveAntenna)
                        uplinkSection
                        NetworkServicesSection(ddnsCount: ddnsCount, portCount: portMappingCount,
                                               onOpenDDNS: onOpenDDNS, onOpenPorts: onOpenPortMapping)
                        wifiSection
                        rebootSection
                        hardwareSection
                    }
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.top, 0)
                    .padding(.bottom, Theme.contentPadding)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                disconnectedState
            }
        }
        .onChange(of: settings) { _, value in
            guard isLive, let value else {
                clearPendingControls()
                return
            }
            if !rebootExpanded {
                draftTime = value.rebootTime; draftWeekday = value.rebootWeekday
            }
        }
        .onChange(of: isLive) { _, live in
            if !live { clearPendingControls() }
        }
        .onAppear {
            if isLive, let settings {
                draftTime = settings.rebootTime.isEmpty ? "04:30" : settings.rebootTime
                draftWeekday = settings.rebootWeekday.isEmpty ? "Everyday" : settings.rebootWeekday
            }
        }
    }

    private var disconnectedState: some View {
        VStack(spacing: 0) {
            PanelHeading("设备控制")
                .padding(.horizontal, Theme.contentPadding)
                .padding(.bottom, Theme.Space.s)
            VStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                Image(systemName: "wifi.slash")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.inkMuted)
                Text("设备已断开连接")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                Text("连接设备后可读取和调整设置")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func clearPendingControls() {
        rebootExpanded = false; draftTime = ""; draftWeekday = ""
        pendingUplink = nil; fanMenuOpen = false
    }

    private var fanTitle: String {
        guard let settings else { return "—" }
        return settings.fan?.title ?? (settings.fanMode.isEmpty ? "—" : "模式 \(settings.fanMode)")
    }

    // MARK: - Uplink modes

    private var uplinkSection: some View {
        let active = settings?.activeUplink
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PanelHeading("上网运行模式")
                Spacer(minLength: 0)
                if settings == nil {
                    ProgressView().controlSize(.mini)
                }
            }
            HStack(spacing: 5) {
                ForEach(UplinkTarget.allCases, id: \.self) { target in
                    modeCard(target, active: active == target)
                }
            }
            if let pendingUplink {
                let bannerShape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                HStack(spacing: 8) {
                    Text("切换到「\(pendingUplink.title)」会短暂断网")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("取消") { self.pendingUplink = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                    Button("确认切换") {
                        let target = pendingUplink
                        self.pendingUplink = nil
                        onSwitchUplink(target)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.accentColor))
                    .accessibilityLabel("确认切换到\(pendingUplink.title)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.panelFill, in: bannerShape)
                .overlay(bannerShape.strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
            }
        }
    }

    private func modeCard(_ target: UplinkTarget, active: Bool) -> some View {
        let switching = switchingTo == target
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        return Button {
            guard !active, target.isSupported, !busy else { return }
            pendingUplink = target
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(active
                              ? Color.accentColor.opacity(0.18)
                              : (target.isSupported ? Color.primary.opacity(0.07) : Color.primary.opacity(0.04)))
                        .frame(width: 26, height: 26)
                    if switching {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: target.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(active
                                             ? AnyShapeStyle(Color.accentColor)
                                             : (target.isSupported
                                                ? AnyShapeStyle(Theme.inkSecondary)
                                                : AnyShapeStyle(Theme.inkMuted)))
                    }
                }

                Text(target.title)
                    .font(.system(size: 10, weight: active ? .bold : .semibold))
                    .foregroundStyle(active
                                     ? AnyShapeStyle(Color.accentColor)
                                     : (target.isSupported
                                        ? AnyShapeStyle(.primary)
                                        : AnyShapeStyle(Theme.inkMuted)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                HStack(spacing: 2.5) {
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                        Text("当前")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    } else if target.isSupported {
                        Circle()
                            .fill(Theme.inkMuted.opacity(0.55))
                            .frame(width: 4, height: 4)
                        Text("可切换")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                    } else {
                        Text("待适配")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                .frame(height: 12)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                active
                    ? AnyShapeStyle(Color.accentColor.opacity(0.13))
                    : AnyShapeStyle(Theme.panelFill),
                in: shape
            )
            .overlay(
                shape.strokeBorder(
                    active ? Color.accentColor.opacity(0.65) : Theme.hairlineStrong,
                    lineWidth: active ? 1.2 : 0.75
                )
            )
            .shadow(color: active ? Color.accentColor.opacity(0.12) : Theme.panelShadow,
                    radius: active ? 6 : 4, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!target.isSupported || busy)
        .accessibilityLabel("\(target.title)\(active ? "，当前模式" : "")")
        .accessibilityHint(target.isSupported ? "点按后需要确认" : "设备支持此模式，本工具尚未适配写入")
    }

    // MARK: - Wi-Fi

    private var wifiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PanelHeading("Wi-Fi 广播")
                Spacer(minLength: 0)
                if let settings, settings.wifi.count > primaryWiFi.count {
                    Button {
                        withAnimation(Theme.snap) { showBackupWiFi.toggle() }
                    } label: {
                        HStack(spacing: 2) {
                            Text("访客 Wi-Fi \(primaryWiFi.count)/\(settings.wifi.count)")
                            Image(systemName: showBackupWiFi ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("访客 Wi-Fi，\(showBackupWiFi ? "已展开" : "已折叠")")
                }
            }

            Panel(padding: 8, spacing: 0) {
                if let settings {
                    let rows = showBackupWiFi ? settings.wifi : primaryWiFi
                    ForEach(rows) { network in
                        WiFiRow(network: network, busy: busy,
                                onToggle: { onToggleSSID(network, $0) },
                                onRename: { onRenameSSID(network, $0) })
                        if network.id != rows.last?.id {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                                .padding(.horizontal, 6)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在读取设置…").font(.system(size: 10.5)).foregroundStyle(Theme.inkSecondary)
                    }
                    .padding(6)
                }
            }
        }
    }

    private var primaryWiFi: [WiFiNetwork] {
        (settings?.wifi ?? []).filter(\.enabled)
    }

    // MARK: - Scheduled reboot

    private var rebootSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading("定时重启计划")
            Panel(padding: 8, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 18)
                    Button {
                        withAnimation(Theme.snap) { rebootExpanded.toggle() }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("定时重启").font(.system(size: 12, weight: .semibold))
                                .fixedSize()
                            Text(rebootSummary)
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(settings == nil)
                    .accessibilityLabel("定时重启，\(rebootSummary)，点击\(rebootExpanded ? "收起" : "展开")")

                    Toggle("", isOn: Binding(
                        get: { settings?.rebootEnabled ?? false },
                        set: { enabled in
                            onSaveReboot(enabled,
                                          settings?.rebootTime ?? draftTime,
                                          settings?.rebootWeekday ?? draftWeekday)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(busy || settings == nil)
                    .accessibilityLabel("启用定时重启")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)

                if rebootExpanded, settings != nil {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("重启时间").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            TextField("04:30", text: $draftTime)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .padding(.horizontal, 8)
                                .frame(width: 86, height: 26)
                                .background(Theme.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
                                .accessibilityLabel("重启时间")
                            Spacer(minLength: 0)
                            Text("日期").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            Picker("", selection: $draftWeekday) {
                                ForEach(Self.weekdays, id: \.value) { day in
                                    Text(day.label).tag(day.value)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityLabel("重复周期")
                        }
                        Text("到达设定时间后设备会自行重启，期间网络中断。")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        if rebootDirty {
                            HStack(spacing: 8) {
                                Spacer(minLength: 0)
                                Button("取消") {
                                    withAnimation(Theme.snap) { cancelRebootEdit() }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                                Button {
                                    onSaveReboot(settings?.rebootEnabled ?? false, draftTime, draftWeekday)
                                    withAnimation(Theme.snap) { rebootExpanded = false }
                                } label: {
                                    Text("保存修改")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .frame(height: 24)
                                        .background(Capsule().fill(Color.accentColor))
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                                .accessibilityLabel("保存定时重启修改")
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var rebootSummary: String {
        guard let settings else { return "—" }
        guard settings.rebootEnabled else { return "已关闭" }
        let day = settings.rebootWeekday.isEmpty ? "" : " · \(Self.weekdayLabel(settings.rebootWeekday))"
        return "\(settings.rebootTime)\(day)"
    }

    /// True while the draft differs from what the device reported.
    private var rebootDirty: Bool {
        guard let settings else { return false }
        return draftTime != settings.rebootTime || draftWeekday != settings.rebootWeekday
    }

    private func cancelRebootEdit() {
        guard let settings else { rebootExpanded = false; return }
        draftTime = settings.rebootTime.isEmpty ? "04:30" : settings.rebootTime
        draftWeekday = settings.rebootWeekday.isEmpty ? "Everyday" : settings.rebootWeekday
        rebootExpanded = false
    }

    /// Wire values stay English (what the firmware accepts); only the labels are localised.
    private static let weekdays: [(value: String, label: String)] = [
        ("Everyday", "每天"), ("Monday", "周一"), ("Tuesday", "周二"),
        ("Wednesday", "周三"), ("Thursday", "周四"), ("Friday", "周五"),
        ("Saturday", "周六"), ("Sunday", "周日")
    ]

    private static func weekdayLabel(_ value: String) -> String {
        weekdays.first { $0.value == value }?.label ?? value
    }

    // MARK: - Hardware tiles

    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading("硬件控制与状态")
            HStack(spacing: 6) {
                Panel(padding: 10, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        Text("机身指示灯")
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Toggle("", isOn: Binding(
                            get: { settings?.ledOn ?? false },
                            set: { value in
                                onSaveLED(value)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(busy || settings == nil)
                        .accessibilityLabel("机身指示灯")
                    }
                    .frame(height: Theme.inlineControlRowHeight)
                }

                Panel(padding: 10, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "fanblades").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        Text("风扇")
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        Button {
                            guard isLive, settings != nil, !busy else { return }
                            fanMenuOpen.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Text(fanTitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .disabled(!isLive || busy || settings == nil)
                        .popover(isPresented: $fanMenuOpen, arrowEdge: .bottom) {
                            VStack(spacing: 2) {
                                ForEach(FanMode.allCases, id: \.self) { mode in
                                    Button {
                                        fanMenuOpen = false
                                        guard isLive, settings != nil, !busy,
                                              mode != settings?.fan else { return }
                                        onSaveFan(mode)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(mode.title).font(.system(size: 11))
                                            Spacer(minLength: 0)
                                            if mode == settings?.fan {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(Color.accentColor)
                                                    .accessibilityHidden(true)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .frame(width: 116, height: 24)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!isLive || settings == nil || busy)
                                    .accessibilityValue(mode == settings?.fan ? "已选择" : "")
                                }
                            }
                            .padding(6)
                        }
                        .accessibilityLabel("风扇模式：\(fanTitle)")
                    }
                    .frame(height: Theme.inlineControlRowHeight)
                }
            }

            Panel(padding: 10, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    Text("MLO 多链路聚合").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    Spacer(minLength: 0)
                    Text(settings?.supportsMLO == true ? "\(settings?.mloGroups ?? 0) 个链路组" : "懒得做")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .opacity(settings?.supportsMLO == true ? 1 : 0.78)
        }
    }
}

/// One SSID row: clean SSID name (tap to rename) and an instant enable switch, without description subtext.
private struct WiFiRow: View {
    let network: WiFiNetwork
    let busy: Bool
    let onToggle: (Bool) -> Void
    let onRename: (String) -> Void

    @State private var name = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    name = network.ssid
                    editing = true
                } label: {
                    Text(network.ssid)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击改名")
                .accessibilityLabel("\(network.ssid)，点击改名")

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(get: { network.enabled }, set: { onToggle($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(busy)
                    .accessibilityLabel("\(network.ssid) 启用")
            }
            if editing {
                HStack(spacing: 6) {
                    TextField("名称", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
                        .onSubmit { commit() }
                    Button("保存") { commit() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("取消") { editing = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding(.leading, 0)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
    }

    private func commit() {
        onRename(name)
        editing = false
    }
}

import SwiftUI
import FHCPECore

/// Online devices: one ungrouped list, search + type filter on a single toolbar row,
/// access type on the right, no dividers and no per-device invented rates.
public struct DevicesPage: View {
    public let devices: [ConnectedDevice]
    public let isLive: Bool
    @Binding public var query: String
    @Binding public var filter: AccessFilter
    public let onReload: () -> Void
    public let onReserveIP: (@MainActor (ConnectedDevice, String) async throws -> Void)?
    @State private var glyphs = DeviceGlyphStore()
    @State private var glyphRevision = 0
    @State private var editingDevice: ConnectedDevice?
    @State private var glyphTarget: ConnectedDevice?

    public init(devices: [ConnectedDevice], isLive: Bool,
                query: Binding<String>, filter: Binding<AccessFilter>,
                onReload: @escaping () -> Void = {},
                onReserveIP: (@MainActor (ConnectedDevice, String) async throws -> Void)? = nil) {
        self.devices = devices; self.isLive = isLive
        self._query = query; self._filter = filter
        self.onReload = onReload
        self.onReserveIP = onReserveIP
    }

    public enum AccessFilter: String, CaseIterable, Identifiable, Sendable {
        case all, wifi24G, wifi5G, wired
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .all: "全部"
            case .wifi24G: "2.4Ghz"
            case .wifi5G: "5.0Ghz"
            case .wired: "以太网"
            }
        }
        func matches(_ device: ConnectedDevice) -> Bool {
            switch self {
            case .all: true
            case .wifi24G: device.access == .wifi24G
            case .wifi5G: device.access == .wifi5G
            case .wired: device.access == .wired
            }
        }
    }

    public var filtered: [ConnectedDevice] {
        guard isLive else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        return devices.filter { device in
            guard filter.matches(device) else { return false }
            guard !q.isEmpty else { return true }
            return device.name.localizedCaseInsensitiveContains(q)
                || device.ip.localizedCaseInsensitiveContains(q)
                || (device.hostname?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, Theme.contentPadding)
                .padding(.top, 0)
            list
                .padding(.top, 8)
        }
        .sheet(item: $editingDevice) { device in
            DHCPReservationEditor(device: device, isLive: isLive, onSave: onReserveIP)
        }
        .sheet(item: $glyphTarget) { device in
            GlyphPicker(device: device, current: glyphs.glyph(for: device)) { choice in
                glyphs.assign(choice, to: device)
                glyphRevision += 1
            }
        }
        .onChange(of: isLive) { _, live in
            if !live { editingDevice = nil; glyphTarget = nil }
        }
    }

    /// Search bar + White Liquid Glass access filter tabs (`全部 / 2.4Ghz / 5.0Ghz / 以太网`).
    private var toolbar: some View {
        VStack(spacing: 6) {
            searchField
            filterTabs
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            TextField("搜索名称或 IP", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            Spacer(minLength: 0)
            Text(summary)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.panelFill, in: CapsulePanelShape(maxRadius: 999))
        .overlay(CapsulePanelShape(maxRadius: 999)
            .strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
    }

    private var filterTabs: some View {
        let barShape = CapsulePanelShape(maxRadius: 999)
        return HStack(spacing: 3) {
            ForEach(AccessFilter.allCases) { item in
                let selected = filter == item
                let count = isLive ? devices.filter(item.matches).count : 0
                Button {
                    withAnimation(Theme.snap) { filter = item }
                } label: {
                    HStack(spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                        if isLive {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.inkMuted))
                        }
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.inkSecondary))
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(
                        barShape.fill(selected ? Color.white.opacity(0.95) : Color.clear)
                    )
                    .overlay(
                        barShape.strokeBorder(selected ? Color.accentColor.opacity(0.38) : Color.clear, lineWidth: 0.75)
                    )
                    .shadow(color: selected ? Color.black.opacity(0.06) : .clear, radius: 3, y: 1)
                    .contentShape(barShape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title)，\(count) 台")
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background(Theme.surface, in: barShape)
        .overlay(barShape.strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
    }

    private var summary: String {
        guard isLive else { return "—" }
        let shown = filtered.count, total = devices.count
        return query.isEmpty && filter == .all ? "\(shown) 台" : "\(shown)/\(total) 台"
    }

    private var list: some View {
        ScrollView(.vertical) {
            if !isLive {
                Color.clear.frame(height: 0)
            } else if filtered.isEmpty {
                emptyState
                    .padding(.horizontal, Theme.contentPadding)
            } else {
                Panel(padding: 6, spacing: 0) {
                    ForEach(filtered) { device in
                        DeviceRow(device: device,
                                  symbol: glyphs.glyph(for: device)?.symbol ?? device.systemSymbol)
                            .id("\(device.id)#\(glyphRevision)")
                            .contextMenu {
                                Button {
                                    editingDevice = device
                                } label: {
                                    Label("设置固定 IP…", systemImage: "pin")
                                }
                                .disabled(onReserveIP == nil
                                          || device.mac?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
                                Divider()
                                // Flat items only: a nested submenu is rebuilt by the once-per-second
                                // refresh while it is open, which closed it under the cursor.
                                Button {
                                    glyphTarget = device
                                } label: {
                                    Label("设置图标…", systemImage: "square.grid.2x2")
                                }
                                Button("恢复自动识别") {
                                    glyphs.assign(nil, to: device)
                                    glyphRevision += 1
                                }
                            }
                        if device.id != filtered.last?.id {
                            Rectangle()
                                .fill(Theme.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, 44)
                                .padding(.trailing, 8)
                        }
                    }
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.bottom, Theme.contentPadding)
            }
        }
        .scrollIndicators(.automatic)
        .onAppear { glyphs.prune(keeping: devices) }
        .onChange(of: devices) { _, new in
            glyphs.prune(keeping: new)
            if let editingDevice, !new.contains(where: { $0.id == editingDevice.id }) {
                self.editingDevice = nil
            }
            if let glyphTarget, !new.contains(where: { $0.id == glyphTarget.id }) {
                self.glyphTarget = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: isLive ? "magnifyingglass" : "wifi.slash")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.inkMuted)
            Text(isLive ? "没有匹配的设备" : "暂无在线设备数据")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            if isLive && (!query.isEmpty || filter != .all) {
                Text("试试其他名称或接入类型").font(Theme.footnote).foregroundStyle(Theme.inkMuted)
            } else {
                Button("重新读取", action: onReload)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 46)
    }
}

private struct DHCPReservationEditor: View {
    let device: ConnectedDevice
    let isLive: Bool
    let onSave: (@MainActor (ConnectedDevice, String) async throws -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var ip: String
    @State private var saving = false
    @State private var saveError: String?
    @FocusState private var ipFocused: Bool

    init(device: ConnectedDevice, isLive: Bool,
         onSave: (@MainActor (ConnectedDevice, String) async throws -> Void)?) {
        self.device = device
        self.isLive = isLive
        self.onSave = onSave
        self._ip = State(initialValue: device.ip)
    }

    private var validationError: String? {
        do {
            _ = try DHCPReservation(mac: device.mac ?? "", ip: ip)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PanelHeading("设置固定 IP")
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(device.mac ?? "—")
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("IPv4 地址")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                TextField("192.168.8.120", text: $ip)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5).monospacedDigit())
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(ipFocused ? Color.accentColor.opacity(0.65) : Theme.hairlineStrong,
                                                   lineWidth: 0.75))
                    .focused($ipFocused)
                    .disabled(saving)
                    .accessibilityLabel("固定 IPv4 地址")
                    .onSubmit(save)
                Text("在路由器中为此设备保留 IP，续租或重新连接后生效。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = saveError ?? validationError {
                StatusBanner(text: error, tone: .error)
            }
            HStack(spacing: Theme.Space.s) {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Spacer(minLength: 0)
                if saving {
                    ProgressView().controlSize(.mini)
                }
                Button(action: save) {
                    Text(saving ? "正在保存…" : "保存固定 IP")
                        .frame(width: 110)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isLive || saving || onSave == nil || validationError != nil)
            }
        }
        .padding(Theme.contentPadding)
        .frame(width: Theme.compactWidth - 32)
        .interactiveDismissDisabled(saving)
        .onAppear { ipFocused = true }
        .onChange(of: ip) { _, _ in saveError = nil }
    }

    private func save() {
        guard isLive, !saving, validationError == nil, let onSave else { return }
        saving = true
        saveError = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await onSave(device, ip.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

private struct DeviceRow: View {
    let device: ConnectedDevice
    let symbol: String
    @State private var hovering = false

    var body: some View {
        let rowShape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        let style = accessStyle
        HStack(spacing: Theme.Space.s) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(style.iconBackground)
                    .frame(width: 30, height: 30)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style.border, lineWidth: 0.75)
                    .frame(width: 30, height: 30)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.foreground)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(device.ip)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                    if let duration = Self.onlineText(device.onlineSeconds) {
                        Text("·")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                        Text(duration)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: Theme.Space.s)
            Text(device.access.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style.foreground)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(style.badgeBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(style.border, lineWidth: 0.75))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(hovering ? Theme.surfaceHover : .clear, in: rowShape)
        .onHover { value in withAnimation(Theme.quick) { hovering = value } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name)，\(device.ip)，\(device.access.title)")
    }

    private struct AccessVisualStyle {
        let foreground: Color
        let iconBackground: Color
        let badgeBackground: Color
        let border: Color
    }

    private var accessStyle: AccessVisualStyle {
        switch device.access {
        case .wifi5G:
            let fg = Color(nsColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.42, green: 0.72, blue: 1.00, alpha: 1.0)
                    : NSColor(srgbRed: 0.04, green: 0.35, blue: 0.84, alpha: 1.0)
            })
            return AccessVisualStyle(
                foreground: fg,
                iconBackground: fg.opacity(0.14),
                badgeBackground: fg.opacity(0.13),
                border: fg.opacity(0.32)
            )
        case .wifi24G:
            let fg = Color(nsColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.30, green: 0.86, blue: 0.76, alpha: 1.0)
                    : NSColor(srgbRed: 0.02, green: 0.46, blue: 0.40, alpha: 1.0)
            })
            return AccessVisualStyle(
                foreground: fg,
                iconBackground: fg.opacity(0.14),
                badgeBackground: fg.opacity(0.13),
                border: fg.opacity(0.32)
            )
        case .wired:
            let fg = Color(nsColor: NSColor(name: nil) { a in
                a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.72, green: 0.76, blue: 0.92, alpha: 1.0)
                    : NSColor(srgbRed: 0.22, green: 0.26, blue: 0.44, alpha: 1.0)
            })
            return AccessVisualStyle(
                foreground: fg,
                iconBackground: fg.opacity(0.14),
                badgeBackground: fg.opacity(0.13),
                border: fg.opacity(0.32)
            )
        case .unknown:
            return AccessVisualStyle(
                foreground: Theme.inkSecondary,
                iconBackground: Color.primary.opacity(0.08),
                badgeBackground: Color.primary.opacity(0.08),
                border: Theme.hairlineStrong
            )
        }
    }

    /// Compact online duration: `12 分` / `3 小时` / `2 天`.
    static func onlineText(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(seconds)
        let days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天" }
        if hours > 0 { return "\(hours) 小时" }
        return "\(minutes) 分"
    }
}

/// Icon chooser shown as a sheet: a grid is easier to hit than a 20-item submenu and is not
/// disturbed by the periodic refresh.
private struct GlyphPicker: View {
    let device: ConnectedDevice
    let current: DeviceGlyph?
    let onChoose: (DeviceGlyph?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PanelHeading("设置图标")
            Text(device.name)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(DeviceGlyph.allCases, id: \.self) { glyph in
                    let selected = current == glyph
                    Button {
                        onChoose(glyph); dismiss()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: glyph.symbol).font(.system(size: 15, weight: .medium))
                            Text(glyph.title).font(.system(size: 9.5)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Theme.hairline,
                                          lineWidth: selected ? 1 : 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(glyph.title)
                }
            }
            HStack {
                Button("恢复自动识别") { onChoose(nil); dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.contentPadding)
        .frame(width: Theme.compactWidth - 32)
    }
}

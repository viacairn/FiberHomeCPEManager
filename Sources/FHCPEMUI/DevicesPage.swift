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
    public let onRemoveReservation: (@MainActor (ConnectedDevice) async throws -> Void)?
    public let reservations: [DHCPReservation]
    @Environment(\.appNotices) private var notices
    @State private var removingReservation = false
    @State private var glyphs = DeviceGlyphStore()
    @State private var glyphEntries: [String: DeviceGlyph] = [:]
    @State private var editingDevice: ConnectedDevice?
    @State private var filterMenuOpen = false

    public init(devices: [ConnectedDevice], isLive: Bool,
                query: Binding<String>, filter: Binding<AccessFilter>,
                onReload: @escaping () -> Void = {},
                onReserveIP: (@MainActor (ConnectedDevice, String) async throws -> Void)? = nil,
                onRemoveReservation: (@MainActor (ConnectedDevice) async throws -> Void)? = nil,
                reservations: [DHCPReservation] = []) {
        self.devices = devices; self.isLive = isLive
        self._query = query; self._filter = filter
        self.onReload = onReload
        self.onReserveIP = onReserveIP
        self.onRemoveReservation = onRemoveReservation
        self.reservations = reservations
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
        let shown = filtered
        deviceCanvas(shown)
        .sheet(item: $editingDevice) { device in
            DHCPReservationEditor(device: device, isLive: isLive, onSave: onReserveIP)
        }
        .onChange(of: isLive) { _, live in
            if !live { editingDevice = nil; filterMenuOpen = false }
        }
    }

    @ViewBuilder private func deviceCanvas(_ shown: [ConnectedDevice]) -> some View {
        if #available(macOS 26.0, *) {
            list(shown)
                .safeAreaBar(edge: .top, spacing: 12) {
                    toolbar(shownCount: shown.count).padding(.horizontal, Theme.contentPadding)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            list(shown)
                .safeAreaInset(edge: .top, spacing: 12) {
                    toolbar(shownCount: shown.count).padding(.horizontal, Theme.contentPadding)
                }
        }
    }

    /// One compact row: search and a capsule opening the same popover style as fan control.
    private func toolbar(shownCount: Int) -> some View {
        HStack(spacing: 8) {
            searchField(summary: summary(shownCount: shownCount))
            accessFilterMenu
        }
    }

    private func searchField(summary: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            TextField("搜索名称或 IP", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("device-search")
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

    private var accessFilterMenu: some View {
        Button { filterMenuOpen.toggle() } label: {
            HStack(spacing: 5) {
                Text(filter.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(filter == .all ? Theme.inkSecondary : Color.accentColor)
            .padding(.horizontal, 10)
            .frame(width: 88, height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Theme.panelFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
        .popover(isPresented: $filterMenuOpen, arrowEdge: .top) {
            VStack(spacing: 2) {
                ForEach(AccessFilter.allCases) { item in
                    let count = isLive ? "\(devices.lazy.filter(item.matches).count) 台" : "—"
                    Button {
                        filterMenuOpen = false
                        filter = item
                    } label: {
                        HStack(spacing: 8) {
                            Text(item.title).font(.system(size: 11))
                            Spacer(minLength: 0)
                            Text(count)
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Theme.inkSecondary)
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .opacity(filter == item ? 1 : 0)
                                .frame(width: 12)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 8)
                        .frame(width: 144, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.title)，\(count)")
                    .accessibilityValue(filter == item ? "已选择" : "")
                }
            }
            .padding(6)
        }
        .accessibilityLabel("接入类型筛选")
        .accessibilityValue(isLive ? filter.title : "\(filter.title)，未连接")
        .accessibilityIdentifier("device-access-filter")
    }

    private func summary(shownCount: Int) -> String {
        guard isLive else { return "—" }
        let total = devices.count
        return query.isEmpty && filter == .all ? "\(shownCount) 台" : "\(shownCount)/\(total) 台"
    }

    private func list(_ shown: [ConnectedDevice]) -> some View {
        return ScrollView(.vertical) {
            if !isLive {
                Color.clear.frame(height: 0)
            } else if shown.isEmpty {
                emptyState
                    .padding(.horizontal, Theme.contentPadding)
            } else {
                Panel(padding: 6, spacing: 0) {
                    ForEach(shown) { device in
                        DeviceRow(device: device,
                                  symbol: glyphs.glyph(for: device, in: glyphEntries)?.symbol ?? device.systemSymbol,
                                  isReserved: isReserved(device))
                            .accessibilityHidden(true)
                            .overlay {
                                DeviceContextMenu(
                                    device: device, glyph: glyphs.glyph(for: device, in: glyphEntries),
                                    canReserveIP: onReserveIP != nil &&
                                        device.mac?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                                    onReserve: { editingDevice = $0 },
                                    onGlyph: { device, glyph in
                                        glyphs.assign(glyph, to: device)
                                        glyphEntries = glyphs.all()
                                    },
                                    isReserved: isReserved(device),
                                    canRemoveReservation: onRemoveReservation != nil && !removingReservation,
                                    onRemove: removeReservation)
                            }
                        if device.id != shown.last?.id {
                            Rectangle()
                                .fill(Theme.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, 44)
                                .padding(.trailing, 8)
                        }
                    }
                }
                .padding(.horizontal, Theme.contentPadding)
            }
        }
        .scrollIndicators(.automatic)
        .onAppear { loadGlyphAssignments() }
        .onChange(of: devices.map { [$0.id, $0.mac ?? "", $0.hostname ?? "", $0.name] }) { _, _ in
            loadGlyphAssignments()
            if let editingDevice, !devices.contains(where: { $0.id == editingDevice.id }) {
                self.editingDevice = nil
            }
        }
    }

    private func loadGlyphAssignments() {
        glyphEntries = glyphs.all()
    }

    private func isReserved(_ device: ConnectedDevice) -> Bool {
        guard let mac = device.mac else { return false }
        let normalized = mac.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":").uppercased()
        return reservations.contains { $0.mac == normalized }
    }

    private func removeReservation(_ device: ConnectedDevice) {
        guard isLive, !removingReservation, let onRemoveReservation else { return }
        removingReservation = true
        Task { @MainActor in
            defer { removingReservation = false }
            do {
                try await onRemoveReservation(device)
            } catch {
                guard !(error is CancellationError), error as? CPEError != .authentication else { return }
                notices?.show(error.localizedDescription, tone: .error)
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
    @Environment(\.appNotices) private var notices
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
        .appReminder(saveError ?? validationError)
        .appNoticeOverlay(top: 36)
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
                guard !(error is CancellationError), error as? CPEError != .authentication else { return }
                saveError = error.localizedDescription
            }
        }
    }
}

private struct DeviceRow: View {
    let device: ConnectedDevice
    let symbol: String
    let isReserved: Bool
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
                HStack(spacing: 5) {
                    Text(device.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isReserved {
                        Label("固定 IP", systemImage: "pin.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                            .fixedSize()
                    }
                }
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
        return MetricFormatter.formatDuration(seconds)?
            .split(separator: " ").prefix(2).joined(separator: " ")
    }
}

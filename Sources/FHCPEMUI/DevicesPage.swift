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
    @State private var glyphs = DeviceGlyphStore()
    @State private var glyphRevision = 0

    public init(devices: [ConnectedDevice], isLive: Bool,
                query: Binding<String>, filter: Binding<AccessFilter>,
                onReload: @escaping () -> Void = {}) {
        self.devices = devices; self.isLive = isLive
        self._query = query; self._filter = filter
        self.onReload = onReload
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
                let count = devices.filter(item.matches).count
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
            if filtered.isEmpty {
                emptyState
                    .padding(.horizontal, Theme.contentPadding)
            } else {
                Panel(padding: 6, spacing: 0) {
                    ForEach(filtered) { device in
                        DeviceRow(device: device,
                                  symbol: glyphs.glyph(for: device)?.symbol ?? device.systemSymbol)
                            .contextMenu {
                                Menu("设置图标") {
                                    ForEach(DeviceGlyph.allCases, id: \.self) { glyph in
                                        Button {
                                            glyphs.assign(glyph, to: device)
                                            glyphRevision += 1
                                        } label: {
                                            Label(glyph.title, systemImage: glyph.symbol)
                                        }
                                    }
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
        .onChange(of: devices) { _, new in glyphs.prune(keeping: new) }
        .id(glyphRevision)
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

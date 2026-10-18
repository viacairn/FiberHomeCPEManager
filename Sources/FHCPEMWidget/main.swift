import SwiftUI
import WidgetKit
import FHCPECore

// MARK: - Timeline

/// Widget timeline driven by a shared file rather than by a network session.
///
/// The extension never logs in to the CPE and never reads the Keychain: it only reads the
/// non-sensitive `WidgetSnapshot` the app publishes into the App Group container. That
/// keeps the account password out of the widget process entirely and lets the widget
/// render even when the app is not running.
struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: WidgetSnapshot(
            state: .connected, model: "LG6851F", network: "5G", uplinkTitle: "蜂窝上行",
            uplinkAvailable: true, signalBars: 4, downloadBps: 102_400_000, uploadBps: 12_800_000,
            todayBytes: 9_420_000_000, monthBytes: 126_800_000_000, deviceCount: 9))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now, snapshot: context.isPreview ? placeholder(in: context).snapshot : load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: .now, snapshot: load())
        // The app reloads timelines after every successful sample, so the fallback policy
        // only matters when the app is closed. A stale reading is shown as stale.
        let next = Date().addingTimeInterval(entry.snapshot?.isLive == true ? 120 : 900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> WidgetSnapshot? {
        SharedSnapshotStore().read()
    }
}

// MARK: - Widget declaration

struct FiberHomeCPEManagerStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.status, provider: StatusProvider()) { entry in
            StatusWidgetView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("CPE 状态")
        .description("显示蜂窝信号、上下行速率与流量，不包含账号信息。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

enum WidgetKind {
    static let status = "FiberHomeCPEManagerStatus"
}

@main
struct FiberHomeCPEManagerWidgetBundle: WidgetBundle {
    var body: some Widget { FiberHomeCPEManagerStatusWidget() }
}

// MARK: - Background

/// The system supplies the widget container; we only add a matching tint. Liquid Glass is
/// not available to widget containers, so no `glassEffect` is used here.
struct WidgetBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            ContainerRelativeShape().fill(.clear)
        } else {
            ContainerRelativeShape().fill(.regularMaterial)
        }
    }
}

// MARK: - Views

struct StatusWidgetView: View {
    let snapshot: WidgetSnapshot?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemLarge: large
        default: medium
        }
    }

    // MARK: Small — signal, rate, uplink lamp

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                SignalGlyph(level: bars)
                Text(network).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 2)
                Circle().fill(lampColor).frame(width: 6, height: 6)
            }
            Spacer(minLength: 6)
            ValueWithUnit(value: rateValue, unit: rateUnit, size: 26)
            Text("下行速率").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(footnote).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Medium — the four overview metrics

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                SignalGlyph(level: bars)
                Text(network).font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(lampColor).frame(width: 6, height: 6)
                    Text(uplinkTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                cell(title: "上行速率", kind: .rate, value: down(\.uploadBps))
                cell(title: "今日流量", kind: .bytes, value: down(\.todayBytes))
            }
            HStack(alignment: .top, spacing: 0) {
                cell(title: "下行速率", kind: .rate, value: down(\.downloadBps))
                cell(title: "本月流量", kind: .bytes, value: down(\.monthBytes))
            }
            HStack {
                Text(modelName).font(.system(size: 9.5)).foregroundStyle(.secondary)
                Spacer()
                Text(footnote).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Large — metrics plus device count and freshness

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                SignalGlyph(level: bars, height: 13)
                Text(network).font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(lampColor).frame(width: 6, height: 6)
                    Text(uplinkTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.15)
            HStack(alignment: .top, spacing: 0) {
                cell(title: "上行速率", kind: .rate, value: down(\.uploadBps), big: true)
                cell(title: "下行速率", kind: .rate, value: down(\.downloadBps), big: true)
            }
            HStack(alignment: .top, spacing: 0) {
                cell(title: "今日流量", kind: .bytes, value: down(\.todayBytes), big: true)
                cell(title: "本月流量", kind: .bytes, value: down(\.monthBytes), big: true)
            }
            Divider().opacity(0.15)
            HStack(spacing: 6) {
                Label(modelName, systemImage: "wifi.router")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if let count = live?.deviceCount {
                    Label("\(count) 台在线", systemImage: "laptopcomputer.and.iphone")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Text(footnote).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .padding(2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Shared pieces

    private enum MetricKind { case rate, bytes }

    private func cell(title: String, kind: MetricKind, value: Double?, big: Bool = false) -> some View {
        let formatted: (value: String, unit: String)? = switch kind {
        case .rate: MetricFormatter.bitRate(value)
        case .bytes: MetricFormatter.bytes(value)
        }
        return VStack(alignment: .leading, spacing: 1) {
            ValueWithUnit(value: formatted?.value, unit: formatted?.unit ?? (kind == .rate ? "Mbps" : "GB"),
                          size: big ? 22 : 18)
            Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Data accessors

    private var live: WidgetSnapshot? { snapshot?.isLive == true ? snapshot : nil }
    private var bars: Int? { live?.signalBars }
    private var network: String { live?.network ?? "—" }
    private var uplinkTitle: String { snapshot?.uplinkTitle ?? "待连接" }
    private var modelName: String { snapshot?.model ?? "FiberHomeCPEManager" }
    private var rateValue: String? { MetricFormatter.bitRate(live?.downloadBps)?.value }
    private var rateUnit: String { MetricFormatter.bitRate(live?.downloadBps)?.unit ?? "Mbps" }

    private var lampColor: Color {
        guard let snapshot else { return .secondary }
        if snapshot.state == .unconfigured { return .secondary }
        return snapshot.uplinkAvailable ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed)
    }

    private func down(_ keyPath: KeyPath<WidgetSnapshot, Double?>) -> Double? {
        guard let live else { return nil }
        return live[keyPath: keyPath]
    }

    private var footnote: String {
        guard let snapshot else { return "打开 FiberHomeCPEManager 连接" }
        switch snapshot.state {
        case .connected: return "更新于 " + snapshot.updated.formatted(date: .omitted, time: .shortened)
        case .stale: return "数据可能已过期"
        case .disconnected: return "未连接"
        case .unconfigured: return "打开 FiberHomeCPEManager 连接"
        }
    }

    private var accessibilityText: String {
        guard let live else { return "FiberHomeCPEManager：\(footnote)" }
        let downRate = MetricFormatter.bitRate(live.downloadBps).map { "\($0.value) \($0.unit)" } ?? "无数据"
        return "FiberHomeCPEManager，\(live.network)，下行 \(downRate)，\(live.uplinkAvailable ? "上行可用" : "上行不可用")"
    }
}

/// Small, static four-bar glyph matching the menu-bar icon.
struct SignalGlyph: View {
    let level: Int?
    var height: CGFloat = 10
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.6) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                    .fill(index < (level ?? 0) ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 2.2, height: height * CGFloat(index + 1) / 4 + 1)
            }
        }
        .frame(height: height + 1, alignment: .bottom)
    }
}

struct ValueWithUnit: View {
    let value: String?
    let unit: String
    var size: CGFloat = 20
    var body: some View {
        HStack(alignment: .top, spacing: 1.5) {
            Text(value ?? "—")
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.system(size: size * 0.34, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
        }
    }
}

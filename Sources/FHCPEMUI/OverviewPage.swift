import SwiftUI
import FHCPECore

/// Overview page: network card, compact traffic metrics and a four-column cellular
/// summary. Content scrolls within the shared page canvas.
public struct OverviewPage: View {
    public let data: PageData
    public let onMoreInfo: () -> Void

    public init(data: PageData, onMoreInfo: @escaping () -> Void) {
        self.data = data
        self.onMoreInfo = onMoreInfo
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 7) {
                    heroCard
                    metricGrid
                    connectionGrid
                    if data.shouldShowCellularSummary {
                        cellularSummary
                    }
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: Hero card

    /// Hero card: large carrier name + signal bars on the left, RAT/mode/band badges on the top right,
    /// vertically aligned 蜂窝网 / 以太网 rows on the bottom left, and high-contrast uplink + status
    /// badges stacked on the bottom right.
    private var heroCard: some View {
        Panel(padding: 9, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if data.shouldShowCellularSummary {
                    SignalBars(level: data.signalBars, activeColor: .accentColor,
                               inactiveColor: Theme.inkMuted.opacity(0.35),
                               barWidth: 3, gap: 2, unit: 2)
                } else {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(heroTitle)
                            .font(.system(size: 16.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let plmn = carrierPLMN {
                            Text(plmn)
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
                Spacer(minLength: 6)
                if data.isLive, data.hasCellularSignal {
                    HStack(spacing: 4) {
                        heroBadge(data.network, tint: .accentColor)
                        if data.isNR, let mode = data.snapshot?.nrMode, !mode.isEmpty {
                            heroBadge(mode, tint: .accentColor)
                        }
                        if data.bandText != "—" {
                            heroBadge(data.bandText, tint: Theme.inkSecondary)
                        }
                    }
                    .fixedSize()
                }
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    addressRow("蜂窝网", data.wanAddress,
                               placeholder: data.isLive ? (data.hasCellularSignal ? "未连接" : "未插卡") : "—")
                    addressRow("以太网", data.ethernetAddress,
                               placeholder: data.isLive ? (data.ethernetConnected ? "已连接" : "未接入") : "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 5) {
                    heroStatusBadge
                    uplinkBadge
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var heroTitle: String {
        guard data.isLive else { return "—" }
        if !data.hasCellularSignal && data.ethernetConnected {
            return "以太网宽带"
        }
        guard let carrierPLMN else { return "—" }
        return CarrierMapper.displayName(for: carrierPLMN)
    }

    private var carrierPLMN: String? {
        guard let plmn = data.radio.plmn ?? data.snapshot?.plmn, !plmn.isEmpty, plmn != "—" else {
            return nil
        }
        return plmn
    }

    private func heroBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6.5)
            .frame(height: 19)
            .background(Capsule().fill(tint.opacity(0.15)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 0.6))
    }

    private func addressRow(_ label: String, _ value: String?, placeholder: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 36, alignment: .leading)
            Text(value ?? placeholder)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? AnyShapeStyle(Theme.inkMuted) : AnyShapeStyle(Color.primary))
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private var uplinkSymbol: String {
        switch data.uplink {
        case .cellular: "antenna.radiowaves.left.and.right"
        case .broadband: "cable.connector"
        case .aggregation: "arrow.triangle.merge"
        case .masterSlave: "arrow.left.arrow.right"
        case .unknown: "network"
        }
    }

    private var uplinkBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: uplinkSymbol)
                .font(.system(size: 9.5, weight: .bold))
            Text(data.uplink.title)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 0.6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前上行模式：\(data.uplink.title)")
    }

    /// Both uplinks are stated: each WAN reports its own `ConnectionStatus`.
    private var heroStatus: (text: String, tone: StatusDot.Tone, tint: Color) {
        guard data.isLive else { return ("设备未连接", .neutral, Theme.inkMuted) }
        return switch (data.cellularConnected, data.ethernetConnected) {
        case (true, true): ("已注册 · 双网在线", .positive, Theme.positive)
        case (true, false): ("已注册", .positive, Theme.positive)
        case (false, true): ("以太网在线", .positive, Theme.positive)
        case (false, false):
            if data.hasCellularSignal {
                ("搜索中", .warning, Theme.warning)
            } else {
                ("未注册", .negative, Theme.negative)
            }
        }
    }

    private var heroStatusBadge: some View {
        let state = heroStatus
        return HStack(spacing: 4.5) {
            StatusDot(state.tone, size: 6)
            Text(state.text)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(state.tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(state.tint.opacity(0.38), lineWidth: 0.6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("网络状态：\(state.text)")
    }

    // MARK: Metric grid

    private var metricGrid: some View {
        let valueFont = Font.system(size: 22, weight: .bold).monospacedDigit()
        return Panel(padding: 8, spacing: 4) {
            Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    MetricCell(value: rate(data.snapshot?.uploadBps), unit: rateUnit(data.snapshot?.uploadBps),
                               caption: "上行速率", valueFont: valueFont,
                               accessibilityValue: rateAccessibility(data.snapshot?.uploadBps))
                    MetricCell(value: traffic(data.snapshot?.todayBytes), unit: trafficUnit(data.snapshot?.todayBytes),
                               caption: "今日流量", valueFont: valueFont,
                               accessibilityValue: trafficAccessibility(data.snapshot?.todayBytes))
                }
                GridRow {
                    MetricCell(value: rate(data.snapshot?.downloadBps), unit: rateUnit(data.snapshot?.downloadBps),
                               caption: "下行速率", valueFont: valueFont,
                               accessibilityValue: rateAccessibility(data.snapshot?.downloadBps))
                    MetricCell(value: traffic(data.snapshot?.monthBytes), unit: trafficUnit(data.snapshot?.monthBytes),
                               caption: "本月流量", valueFont: valueFont,
                               accessibilityValue: trafficAccessibility(data.snapshot?.monthBytes))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Compact 2x2 Bento card: online devices, SMS count, uptime, module temperature.
    private var connectionGrid: some View {
        Panel(padding: 8, spacing: 5) {
            Grid(horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    StatCell(label: "在线设备", value: data.deviceCount.map { "\($0) 台" })
                    StatCell(label: "短信", value: data.smsCount.map { "\($0) 条" })
                }
                GridRow {
                    StatCell(label: "运行时间", value: data.uptimeText)
                    StatCell(label: "模组温度", value: data.snapshot?.temperature.map { "\($0) ℃" })
                }
            }
        }
    }

    /// A stat cell with the five-segment quality meter under the number.
    private func signalCell(_ label: String, value: String?,
                            quality: (level: Int, tint: Color)) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            Text(value ?? "—")
                .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                .foregroundStyle(value == nil ? Theme.inkMuted : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            LevelMeter(level: quality.level, tint: quality.tint)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value ?? "未知")")
    }

    /// Local sizing keeps the four-column summary readable without changing shared cells.
    private func cellularStat(_ label: String, value: String?) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            Text(value ?? "—")
                .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                .foregroundStyle(value == nil ? Theme.inkMuted : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value ?? "未知")")
    }

    // MARK: Cellular summary

    private var cellularSummary: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                PanelHeading("蜂窝信息")
                let carrierCount = data.snapshot?.carrierCount
                let aggregated = (carrierCount ?? 0) > 1
                Text(carrierCount == nil ? "—" : (data.snapshot?.carrierAggregationLabel ?? "—"))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(aggregated ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(Theme.inkSecondary))
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((aggregated ? Color.accentColor : Color.primary)
                        .opacity(aggregated ? 0.15 : 0.08)))
                    .overlay(Capsule().strokeBorder(aggregated ? Color.accentColor.opacity(0.32) : Theme.hairline, lineWidth: 0.5))
                Spacer(minLength: 0)
                Button(action: onMoreInfo) {
                    HStack(spacing: 3) {
                        Text("更多")
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Theme.surface, in: CapsulePanelShape(maxRadius: 999))
                    .overlay(CapsulePanelShape(maxRadius: 999).strokeBorder(Theme.hairlineStrong, lineWidth: 0.6))
                    .contentShape(CapsulePanelShape(maxRadius: 999))
                }
                .buttonStyle(.plain)
                .help("基站与小区、载波聚合与锁定配置")
                .accessibilityLabel("更多")
            }
            Panel(padding: 8, spacing: 6) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: 4), spacing: 7) {
                    signalCell("RSRP", value: FieldFormat.dbm(data.radio.rsrp),
                               quality: SignalQuality.rsrp(MetricFormatter.number(data.radio.rsrp)))
                    signalCell("RSRQ", value: FieldFormat.db(data.radio.rsrq),
                               quality: SignalQuality.rsrq(MetricFormatter.number(data.radio.rsrq)))
                    signalCell("SINR", value: FieldFormat.db(data.radio.sinr),
                               quality: SignalQuality.sinr(MetricFormatter.number(data.radio.sinr)))
                    cellularStat("RSSI", value: FieldFormat.dbm(data.radio.rssi))

                    // Where the device is camped, broad to narrow: tracking area, cell,
                    // physical cell id, carrier frequency.
                    cellularStat("TAC", value: data.radio.tac)
                    cellularStat(data.isNR ? "NCI" : "Cell ID", value: data.radio.cell.map(FieldFormat.hex))
                    cellularStat("PCI", value: data.radio.pci)
                    cellularStat(data.isNR ? "NR-ARFCN" : "EARFCN", value: data.radio.arfcn)

                    cellularStat("QCI 承载等级", value: data.radio.qci)
                    cellularStat("上行签约速率", value: ulAmbrText)
                    cellularStat("下行签约速率", value: dlAmbrText)
                    cellularStat("CQI", value: data.radio.cqi)
                }
            }
        }
    }

    // MARK: Formatting

    private func rate(_ bits: Double?) -> String? {
        guard data.isLive else { return nil }
        return MetricFormatter.bitRate(bits)?.value
    }
    private func rateUnit(_ bits: Double?) -> String? {
        guard data.isLive else { return nil }
        return MetricFormatter.bitRate(bits)?.unit
    }
    private func rateAccessibility(_ bits: Double?) -> String {
        guard data.isLive, let value = MetricFormatter.bitRate(bits) else { return "无数据" }
        return "\(value.value) \(value.unit)"
    }

    /// Contracted uplink rate from the AMBR node, e.g. "102 Mbps".
    private var ulAmbrText: String? {
        Self.formatAmbr(data.radio.ulAmbrKbps)
    }

    /// Contracted downlink rate from the AMBR node, e.g. "512 Mbps".
    private var dlAmbrText: String? {
        Self.formatAmbr(data.radio.dlAmbrKbps)
    }

    private static func formatAmbr(_ kbps: Double?) -> String? {
        guard let kbps, kbps > 0 else { return nil }
        let value = Double(kbps)
        return value >= 1000 ? "\(Int(value / 1000)) Mbps" : "\(Int(value)) Kbps"
    }

    private func traffic(_ bytes: Double?) -> String? {
        guard data.isLive else { return nil }
        return MetricFormatter.bytes(bytes)?.value
    }
    private func trafficUnit(_ bytes: Double?) -> String? {
        guard data.isLive else { return nil }
        return MetricFormatter.bytes(bytes)?.unit
    }
    private func trafficAccessibility(_ bytes: Double?) -> String {
        guard data.isLive, let value = MetricFormatter.bytes(bytes) else { return "无数据" }
        return "\(value.value) \(value.unit)"
    }
}

// MARK: - Page view model

/// Everything a page needs, resolved once per render so views stay declarative and free
/// of optional-chaining noise. `snapshot == nil` means "no live evidence": every value
/// renders as "—" rather than a fabricated zero.
public struct PageData: Sendable, Equatable {
    private var rawSnapshot: DeviceSnapshot?
    /// A retained or late reading is never presented without a live session.
    public var snapshot: DeviceSnapshot? {
        get { isLive ? rawSnapshot : nil }
        set { rawSnapshot = newValue }
    }
    private var rawDevices: [ConnectedDevice]
    public var devices: [ConnectedDevice] {
        get { isLive ? rawDevices : [] }
        set { rawDevices = newValue }
    }
    public var stale: Bool
    public var connected: Bool

    public init(snapshot: DeviceSnapshot?, devices: [ConnectedDevice] = [], stale: Bool = false, connected: Bool = false) {
        self.rawSnapshot = snapshot; self.rawDevices = devices; self.stale = stale; self.connected = connected
    }

    public var isLive: Bool { connected && !stale && rawSnapshot != nil }
    public var model: String {
        guard let snapshot, !snapshot.model.isEmpty else { return "待连接" }
        return snapshot.model
    }
    public var statusText: String {
        if connected { return stale ? "连接待确认" : "已连接" }
        return "未连接"
    }
    public var network: String {
        guard isLive, let snapshot, !snapshot.network.isEmpty else { return "—" }
        return snapshot.network
    }
    public var radio: RadioReading { snapshot?.servingRadio ?? RadioReading() }
    public var isNR: Bool { snapshot?.activeTech == .nr }
    public var signalBars: Int? { isLive ? snapshot?.signalBars : nil }
    public var deviceCount: Int? { isLive ? devices.count : nil }

    /// True when the modem reports a SIM/carrier or any active RF measurement.
    public var hasCellularSignal: Bool {
        guard isLive else { return false }
        if cellularConnected { return true }
        if radio.hasAnyValue { return true }
        if let bars = signalBars, bars > 0 { return true }
        if let plmn = radio.plmn ?? snapshot?.plmn, !plmn.isEmpty, plmn != "—" { return true }
        return false
    }

    /// Hide cellular panels when the device is live on Ethernet uplink (or without SIM) and
    /// has no cellular signal/registration at all. Offline preview still renders placeholders.
    public var shouldShowCellularSummary: Bool {
        guard isLive else { return true }
        return hasCellularSignal
    }

    /// WAN address as reported by the firmware (e.g. `198.51.100.20`).
    public var wanAddress: String? {
        guard isLive, let address = snapshot?.wanAddress, !address.isEmpty else { return nil }
        return address
    }

    /// Human uptime. `DeviceInfo.UpTime` is whole seconds on RP0112; the WAN session
    /// uptime is the fallback.
    public var uptimeText: String? {
        guard isLive, let snapshot else { return nil }
        if let text = snapshot.uptime, !text.isEmpty {
            guard let seconds = Double(text) else { return text }
            return Self.duration(seconds)
        }
        guard let seconds = snapshot.wanUptime, seconds > 0 else { return nil }
        return Self.duration(seconds)
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }
    /// Message count reported by the device (bodies may be unreadable).
    public var smsCount: Int? { isLive ? snapshot?.smsCount : nil }
    public var uplink: UplinkMode { snapshot?.uplink ?? .unknown }
    public var uplinkAvailable: Bool { isLive && (snapshot?.uplinkAvailable ?? false) }

    /// Live cellular WAN state (WANDevice.1).
    public var cellularConnected: Bool { isLive && (snapshot?.cellularConnected ?? false) }

    /// Live Ethernet WAN state; false while disconnected or when the port has no link.
    public var ethernetConnected: Bool { isLive && (snapshot?.ethernetConnected ?? false) }

    /// Ethernet WAN external address (WANDevice.2), when the device reports one.
    public var ethernetAddress: String? {
        guard isLive, let address = snapshot?.ethernetAddress else { return nil }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "0.0.0.0" ? nil : trimmed
    }

    /// Band from the active radio, always displayed uppercase (n78 → N78).
    public var bandText: String {
        guard isLive, let band = radio.band, !band.isEmpty else { return "—" }
        return band.uppercased()
    }

    public var uplinkHelp: String {
        guard isLive else { return "未连接设备，无法确认上行可用性" }
        let evidence = snapshot?.uplinkEvidence ?? ""
        return uplinkAvailable
            ? "设备已确认当前上行可用（\(uplink.title)）\(evidence.isEmpty ? "" : " · \(evidence)")"
            : "当前无法确认上行可用（\(uplink.title)）\(evidence.isEmpty ? "" : " · \(evidence)")"
    }
}

// MARK: - Small formatting helpers shared across pages

public enum FieldFormat {
    public static func dbm(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.contains("dBm") ? raw : "\(raw) dBm"
    }
    public static func db(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.contains("dB") ? raw : "\(raw) dB"
    }
    public static func hex(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") { return trimmed }
        if let value = UInt64(trimmed) { return "0x" + String(value, radix: 16, uppercase: false) }
        return trimmed
    }
}

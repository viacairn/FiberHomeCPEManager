import SwiftUI
import FHCPECore

/// Cellular detail page, at the same 340 pt width and 560 pt height as every other page.
///
/// The dense tables scroll rather than forcing a wider window: one window size for the
/// whole app, content that grows downwards. This is the only place a cell lock can be
/// initiated.
public struct CellularDetailPage: View {
    public let data: PageData
    public let cells: [CellRecord]
    public let lockMode: LockMode
    public let lockBusy: Bool
    public let onBack: () -> Void
    public let onRefreshCells: () -> Void
    public let onLockCurrent: (CellRecord?) -> Void
    public let lockState: RadioLockState?
    public let onSetCellLockEnabled: ((Bool) -> Void)?
    public let onSetBandLockEnabled: ((Bool, [Int], [Int]) -> Void)?
    public let onAddLockedCell: ((LockedCell) -> Void)?
    public let onUpdateLockedCell: ((LockedCell) -> Void)?
    public let onDeleteLockedCell: ((LockedCell) -> Void)?
    public let onDisableLocks: (() -> Void)?

    public var initialTab = 0
    @State private var tab = 0
    @State private var selection: String?
    @State private var lteBandText = ""
    @State private var nrBandText = ""
    @State private var cellEditorPresented = false
    @State private var editingCellIndex: Int?
    @State private var editingCellAct = 2
    @State private var editingCellARFCN = ""
    @State private var editingCellPCI = ""

    /// Firmware band values are either bare numbers (78) or already prefixed (N78/B3).
    /// Display them uppercase without adding a second prefix.
    static func uppercaseBand(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        let upper = trimmed.uppercased()
        return upper.hasPrefix("N") || upper.hasPrefix("B") ? upper : "N\(upper)"
    }

    public init(data: PageData, cells: [CellRecord], lockMode: LockMode, lockBusy: Bool,
                onBack: @escaping () -> Void, onRefreshCells: @escaping () -> Void,
                onLockCurrent: @escaping (CellRecord?) -> Void,
                initialTab: Int = 0, lockState: RadioLockState? = nil,
                onSetCellLockEnabled: ((Bool) -> Void)? = nil,
                onSetBandLockEnabled: ((Bool, [Int], [Int]) -> Void)? = nil,
                onAddLockedCell: ((LockedCell) -> Void)? = nil,
                onUpdateLockedCell: ((LockedCell) -> Void)? = nil,
                onDeleteLockedCell: ((LockedCell) -> Void)? = nil,
                onDisableLocks: (() -> Void)? = nil) {
        self.data = data; self.cells = cells; self.lockMode = lockMode; self.lockBusy = lockBusy
        self.initialTab = initialTab
        self.onBack = onBack; self.onRefreshCells = onRefreshCells; self.onLockCurrent = onLockCurrent
        self.lockState = lockState; self.onSetCellLockEnabled = onSetCellLockEnabled
        self.onSetBandLockEnabled = onSetBandLockEnabled; self.onAddLockedCell = onAddLockedCell
        self.onUpdateLockedCell = onUpdateLockedCell; self.onDeleteLockedCell = onDeleteLockedCell
        self.onDisableLocks = onDisableLocks
    }

    public var body: some View {
        VStack(spacing: 0) {
            SubpageBar(title: "蜂窝详情", onBack: onBack)
            segment
                .padding(.horizontal, Theme.contentPadding)
                .padding(.top, 8)
            Group {
                switch tab {
                case 0: metricsTab
                default: cellsTab
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear {
                if initialTab != 0 { tab = initialTab }
                loadBandDrafts()
            }
        }
        .onChange(of: lockState) { _, _ in loadBandDrafts() }
        .onChange(of: data.isLive) { _, live in
            if !live {
                cellEditorPresented = false; selection = nil
                editingCellIndex = nil; editingCellARFCN = ""; editingCellPCI = ""
                lteBandText = ""; nrBandText = ""
            }
        }
        .sheet(isPresented: $cellEditorPresented) { cellEditor }
    }

    private var segment: some View {
        WideTabBar(items: [.init(id: 0, title: "技术指标"), .init(id: 1, title: "基站与小区")],
                   selection: $tab)
    }

    // MARK: - Tab 0: Technical metrics (技术指标)

    private var metricsTab: some View {
        ScrollView(.vertical) {
            VStack(spacing: 9) {
                servingHeroCard
                signalQualityPanel
                carrierAggregation
                networkAndLinkPanel
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 8)
            .padding(.bottom, Theme.Space.m)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }

    /// Top summary card showing operator, active radio technology, band, PCI/ARFCN, and uplink badge.
    private var servingHeroCard: some View {
        Panel(padding: 11, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(data.network)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)
                        if data.isLive, let nrMode = data.snapshot?.nrMode, !nrMode.isEmpty {
                            Text(nrMode)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor, in: Capsule())
                        }
                        if data.bandText != "—" {
                            Text(data.bandText)
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 0.75))
                        }
                    }
                    let plmn = data.isLive ? (data.radio.plmn ?? data.snapshot?.plmn) : nil
                    let operatorName = plmn.map { CarrierMapper.displayName(for: $0) } ?? "—"
                    Text("\(operatorName) · PCI \(data.radio.pci ?? "—") · 频点 \(data.radio.arfcn ?? "—")")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 4) {
                        StatusDot(data.isLive ? (data.uplinkAvailable ? .positive : .negative) : .neutral, size: 6)
                        Text(data.isLive ? data.uplink.title : "—")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
                    .help(data.uplinkHelp)

                    SignalBars(level: data.signalBars, activeColor: .accentColor,
                               inactiveColor: Theme.inkMuted.opacity(0.35),
                               barWidth: 3, gap: 2, unit: 2)
                }
            }
        }
    }

    /// Primary RF measurements with color-coded signal quality bars + secondary RF row.
    private var signalQualityPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeading("射频信号质量", trailing: data.isLive ? "实时测量" : "—")
            Panel(padding: 9, spacing: 7) {
                HStack(spacing: 6) {
                    rfGaugeTile(
                        label: "RSRP",
                        value: FieldFormat.dbm(data.radio.rsrp),
                        quality: rsrpQuality(MetricFormatter.number(data.radio.rsrp))
                    )
                    rfGaugeTile(
                        label: "RSRQ",
                        value: FieldFormat.db(data.radio.rsrq),
                        quality: rsrqQuality(MetricFormatter.number(data.radio.rsrq))
                    )
                    rfGaugeTile(
                        label: "SINR",
                        value: FieldFormat.db(data.radio.sinr),
                        quality: sinrQuality(MetricFormatter.number(data.radio.sinr))
                    )
                }
                HStack(spacing: 6) {
                    StatCell(label: "RSSI", value: FieldFormat.dbm(data.radio.rssi),
                             valueFont: .system(size: 12, weight: .bold).monospacedDigit())
                    StatCell(label: "发射功率", value: FieldFormat.dbm(data.radio.power),
                             valueFont: .system(size: 12, weight: .bold).monospacedDigit())
                    StatCell(label: "CQI 信道质量", value: data.radio.cqi,
                             valueFont: .system(size: 12, weight: .bold).monospacedDigit())
                }
            }
        }
    }

    private struct RFQuality {
        let tag: String
        let color: Color
        let fraction: Double
    }

    private func rsrpQuality(_ rsrp: Double?) -> RFQuality {
        guard let rsrp else { return RFQuality(tag: "—", color: Theme.inkMuted, fraction: 0) }
        if rsrp >= -85 { return RFQuality(tag: "极佳", color: Theme.positive, fraction: 0.92) }
        if rsrp >= -95 { return RFQuality(tag: "良好", color: Color.accentColor, fraction: 0.72) }
        if rsrp >= -105 { return RFQuality(tag: "一般", color: Theme.warning, fraction: 0.48) }
        return RFQuality(tag: "较弱", color: Theme.negative, fraction: 0.25)
    }

    private func rsrqQuality(_ rsrq: Double?) -> RFQuality {
        guard let rsrq else { return RFQuality(tag: "—", color: Theme.inkMuted, fraction: 0) }
        if rsrq >= -10 { return RFQuality(tag: "极佳", color: Theme.positive, fraction: 0.90) }
        if rsrq >= -15 { return RFQuality(tag: "良好", color: Color.accentColor, fraction: 0.68) }
        if rsrq >= -20 { return RFQuality(tag: "一般", color: Theme.warning, fraction: 0.42) }
        return RFQuality(tag: "较弱", color: Theme.negative, fraction: 0.22)
    }

    private func sinrQuality(_ sinr: Double?) -> RFQuality {
        guard let sinr else { return RFQuality(tag: "—", color: Theme.inkMuted, fraction: 0) }
        if sinr >= 15 { return RFQuality(tag: "极佳", color: Theme.positive, fraction: 0.92) }
        if sinr >= 5 { return RFQuality(tag: "良好", color: Color.accentColor, fraction: 0.70) }
        if sinr >= 0 { return RFQuality(tag: "一般", color: Theme.warning, fraction: 0.45) }
        return RFQuality(tag: "干扰高", color: Theme.negative, fraction: 0.22)
    }

    private func rfGaugeTile(label: String, value: String?, quality: RFQuality) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: 0)
                Text(quality.tag)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(quality.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(quality.color.opacity(0.14), in: Capsule())
            }
            Text(value ?? "—")
                .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 4)
                    Capsule()
                        .fill(quality.color)
                        .frame(width: max(0, geo.size.width * quality.fraction), height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
    }

    private var carrierAggregation: some View {
        let carriers = data.isLive ? (data.snapshot?.carriers ?? []) : []
        let primary = carriers.first { $0.role == .primary }
        let secondaries = carriers.filter { $0.role == .secondary && $0.isPresent }
        let label = data.snapshot?.carrierAggregationLabel ?? "单载波 PCC"
        return VStack(alignment: .leading, spacing: 4) {
            PanelHeading("载波聚合状态",
                         trailing: data.isLive ? (secondaries.isEmpty ? "单载波 · 未激活 SCC" : label) : "—")
            Panel(padding: 8, spacing: 4) {
                if data.isLive {
                    carrierRow(badge: "PCC", name: "主载波", component: primary, fallback: primaryFallback, isPrimary: true)
                    ForEach(secondaries) { component in
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        carrierRow(badge: "SCC\(component.index)", name: "辅载波", component: component,
                                   fallback: "—", isPrimary: false)
                    }
                } else {
                    HStack {
                        Text("当前载波")
                            .foregroundStyle(Theme.inkSecondary)
                        Spacer()
                        Text("—")
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var primaryFallback: String {
        let band = data.bandText == "—" ? nil : data.bandText
        let parts = [data.network, band, data.radio.pci.map { "PCI \($0)" }, data.radio.arfcn.map { "频点 \($0)" }]
            .compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func carrierRow(badge: String, name: String, component: CarrierComponent?,
                            fallback: String, isPrimary: Bool) -> some View {
        let accent = isPrimary ? Color.accentColor : Theme.positive
        return HStack(spacing: 6) {
            Text(badge)
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(accent.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(accent.opacity(0.32), lineWidth: 0.75))
            Text(name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            if let component {
                let bandText: String = component.band.map(Self.uppercaseBand) ?? "—"
                let pciText: String = component.pci.map { "PCI \($0)" } ?? "—"
                let arfcnText: String = component.arfcn.map { "频点 \($0)" } ?? "—"
                Text("\(bandText) · \(pciText) · \(arfcnText)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text(fallback)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            StatusDot(.positive, size: 5.5)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    /// Combined network registration & link contract panel.
    private var networkAndLinkPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeading("基站标识与签约参数")
            Panel(padding: 8, spacing: 6) {
                HStack(spacing: 6) {
                    StatCell(label: "TAC 跟踪区", value: data.radio.tac,
                             valueFont: .system(size: 12, weight: .bold).monospacedDigit())
                    StatCell(label: "Cell ID (NCI)", value: data.radio.cell.map(FieldFormat.hex),
                             valueFont: .system(size: 11.5, weight: .bold).monospacedDigit())
                    StatCell(label: "PLMN", value: data.isLive ? (data.radio.plmn ?? data.snapshot?.plmn) : nil,
                             valueFont: .system(size: 12, weight: .bold).monospacedDigit())
                }
                HStack(spacing: 6) {
                    StatCell(label: "上行签约速率", value: ambr(data.radio.ulAmbrKbps),
                             valueFont: .system(size: 12, weight: .bold).monospacedDigit())
                    StatCell(label: "下行签约速率", value: ambr(data.radio.dlAmbrKbps),
                             valueFont: .system(size: 12, weight: .bold).monospacedDigit())
                    StatCell(label: "QCI 承载等级", value: data.radio.qci,
                             valueFont: .system(size: 12, weight: .bold).monospacedDigit())
                }
            }
        }
    }

    /// AMBR is reported in kbit/s; present it as a bit rate without inventing a unit.
    private func ambr(_ kbps: Double?) -> String? {
        guard let kbps, kbps > 0 else { return nil }
        guard let value = MetricFormatter.bitRate(kbps * 1000) else { return nil }
        return "\(value.value) \(value.unit)"
    }

    private var servingCell: CellRecord? {
        data.isLive ? cells.first { $0.state == .serving } : nil
    }

    // MARK: - Tab 1: Base Station & Cells (基站与小区)

    private var cellsTab: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        PanelHeading("可发现基站与邻区")
                        Text(data.isLive ? "共 \(cells.count) 个" : "—")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
                    }
                    Spacer()
                    Button {
                        onRefreshCells()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .semibold))
                            Text("刷新邻区")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(data.isLive ? Color.accentColor : Theme.inkMuted)
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(
                            CapsulePanelShape(maxRadius: 999).fill(data.isLive ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            CapsulePanelShape(maxRadius: 999).strokeBorder(data.isLive ? Color.accentColor.opacity(0.38) : Theme.hairlineStrong, lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!data.isLive)
                }

                cellCardsList

                lockSection(current: selectedCell)
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 8)
            .padding(.bottom, Theme.Space.m)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var selectedCell: CellRecord? {
        guard let selection else { return nil }
        return cells.first { $0.id == selection }
    }

    private var cellCardsList: some View {
        Panel(padding: 7, spacing: 5) {
            if !data.isLive || cells.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.inkMuted)
                    Text(data.isLive ? "设备未返回可发现小区" : "暂无小区数据")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(cells) { cell in
                    cellCardRow(cell)
                }
            }
        }
    }

    private func cellCardRow(_ cell: CellRecord) -> some View {
        let isSelected = selection == cell.id
        let isServing = cell.state == .serving
        let rowShape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        let rsrpNum = MetricFormatter.number(cell.rsrp)
        let rsrpColor = rsrpQuality(rsrpNum).color
        let badgeColor = isServing ? Theme.positive : Color.accentColor

        return Button {
            selection = isSelected ? nil : cell.id
        } label: {
            HStack(spacing: 8) {
                // Status + Band pill column
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        StatusDot(isServing ? .positive : .neutral, size: 5.5)
                        Text(cell.state.title)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isServing ? badgeColor : Theme.inkSecondary)
                    }
                    Text("\(cell.tech.title) · \(Self.uppercaseBand(cell.band))")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .frame(width: 74, alignment: .leading)

                // PCI & ARFCN column
                VStack(alignment: .leading, spacing: 2.5) {
                    Text("PCI \(cell.pci)")
                        .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text("频点 \(cell.channel ?? "—")")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Signal pills (RSRP & SINR)
                HStack(spacing: 5) {
                    VStack(alignment: .trailing, spacing: 1.5) {
                        Text("RSRP")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                        Text(FieldFormat.dbm(cell.rsrp) ?? "—")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(rsrpNum != nil ? rsrpColor : Theme.inkSecondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .trailing, spacing: 1.5) {
                        Text("SINR")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                        Text(FieldFormat.db(cell.sinr) ?? "—")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.14)
                    : (isServing ? Theme.surface : Color.white.opacity(0.55)),
                in: rowShape
            )
            .overlay(
                rowShape.strokeBorder(
                    isSelected
                        ? Color.accentColor.opacity(0.65)
                        : (isServing ? Theme.hairlineStrong : Theme.hairline),
                    lineWidth: isSelected ? 1.2 : 0.75
                )
            )
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cell.tech.title) \(cell.band) PCI \(cell.pci)，\(cell.state.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func lockSection(current: CellRecord?) -> some View {
        let target = current ?? servingCell
        let enabled = canConfigureLocks && target.map(Self.isLockableCell) == true
        let lockedList = effectiveLockState.cells
        let pill = CapsulePanelShape(maxRadius: 999)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PanelHeading("小区锁定与选网策略")
                Spacer()
                Text(lockState?.hasConflict == true ? "锁定冲突" : (lockState?.mode ?? lockMode).title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(lockMode.isAutomatic ? Theme.inkSecondary : Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        (lockMode.isAutomatic ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.14)),
                        in: Capsule()
                    )
            }
            Panel(padding: 10, spacing: 7) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("锁小区")
                            .font(.system(size: 11, weight: .bold))
                        Text("使用候选列表，与锁频段互斥")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Spacer(minLength: 4)
                    Toggle("锁小区", isOn: Binding(
                        get: { effectiveLockState.cellLockEnabled },
                        set: { onSetCellLockEnabled?($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!canConfigureLocks || onSetCellLockEnabled == nil ||
                              (!effectiveLockState.cellLockEnabled && lockedList.isEmpty))
                }
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current == nil ? "当前服务小区" : "已选锁定目标")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                        if let target {
                            Text("\(target.tech.title) · \(Self.uppercaseBand(target.band)) · PCI \(target.pci) · 频点 \(target.channel ?? "—")")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        } else {
                            Text("缺少服务小区信息，无法锁定")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.inkMuted)
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        onLockCurrent(target)
                    } label: {
                        Text(current == nil ? "锁定当前小区" : "锁定所选小区")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(enabled ? .white : Theme.inkMuted)
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(
                                pill.fill(enabled ? Color.accentColor : Color.primary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                }

                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("已配置的锁定候选小区 (\(lockedList.count))")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                        Spacer()
                        Button {
                            presentCellEditor(nil)
                        } label: {
                            Label("添加", systemImage: "plus")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(!canConfigureLocks || onAddLockedCell == nil || lockedList.count >= 20)
                    }
                    if lockedList.isEmpty {
                        Text("添加候选小区后即可启用；最多可保存 20 个。")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    } else {
                        ForEach(lockedList) { item in
                            HStack(spacing: 6) {
                                Text(item.techTitle)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                                Text("PCI \(item.pciDisplay) · 频点 \(item.arfcn)")
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Theme.inkSecondary)
                                Spacer()
                                Button {
                                    presentCellEditor(item)
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .help("编辑候选小区")
                                .accessibilityLabel("编辑 \(item.techTitle) PCI \(item.pciDisplay)")
                                .disabled(!canConfigureLocks || onUpdateLockedCell == nil)
                                Button {
                                    onDeleteLockedCell?(item)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.inkSecondary)
                                .help("删除候选小区")
                                .accessibilityLabel("删除 \(item.techTitle) PCI \(item.pciDisplay)")
                                .disabled(!canConfigureLocks || onDeleteLockedCell == nil)
                            }
                        }
                    }
                }
            }
            bandLockPanel
                .padding(.top, 5)
            if let reason = lockState?.configurationBlockedReason {
                Text(reason)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if effectiveLockState.hasConflict {
                Text("锁小区与锁频段同时开启，请先全部关闭以恢复自动选网。")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if effectiveLockState.cellLockEnabled || effectiveLockState.bandLockEnabled {
                Button(effectiveLockState.hasConflict ? "全部关闭并修复" : "恢复自动选网") {
                    onDisableLocks?()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .background(Color.accentColor.opacity(0.10), in: pill)
                .overlay(pill.strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.75))
                .disabled(!data.isLive || lockBusy || onDisableLocks == nil)
                .padding(.top, 4)
            }
        }
    }

    private var effectiveLockState: RadioLockState {
        if let lockState { return lockState }
        switch lockMode {
        case .automatic, .unknown:
            return RadioLockState(cells: data.snapshot?.lockedCells ?? [])
        case .cell:
            return RadioLockState(cellLockEnabled: true, cells: data.snapshot?.lockedCells ?? [])
        case .bands(let lte, let nr):
            return RadioLockState(bandLockEnabled: true, cells: data.snapshot?.lockedCells ?? [], lteBands: lte, nrBands: nr)
        }
    }

    private var canConfigureLocks: Bool {
        data.isLive && !lockBusy && effectiveLockState.configurationBlockedReason == nil && !effectiveLockState.hasConflict
    }

    private static func isLockableCell(_ cell: CellRecord) -> Bool {
        (cell.tech == .nr || cell.tech == .lte) &&
        cell.channel.flatMap(Int.init).map { (0...875000).contains($0) } == true &&
        Int(cell.pci).map { (0...2000).contains($0) } == true
    }

    private var bandLockPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeading("频段锁定")
            Panel(padding: 10, spacing: 7) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("锁频段")
                            .font(.system(size: 11, weight: .bold))
                        Text("开启时自动关闭锁小区")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Spacer()
                    Toggle("锁频段", isOn: Binding(
                        get: { effectiveLockState.bandLockEnabled },
                        set: { enabled in
                            onSetBandLockEnabled?(enabled, parsedLTEBands ?? [], parsedNRBands ?? [])
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!canConfigureLocks || onSetBandLockEnabled == nil ||
                              (!effectiveLockState.bandLockEnabled && !bandDraftIsValid))
                }
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                bandInput(label: "4G LTE", text: $lteBandText, prefix: "B", supported: effectiveLockState.supportedLTEBands)
                bandInput(label: "5G NR", text: $nrBandText, prefix: "N", supported: effectiveLockState.supportedNRBands)
                HStack(alignment: .center, spacing: 7) {
                    Text(effectiveLockState.supportedLTEBands.contains(12)
                         ? "频段以逗号分隔；B12/B17 合并选择。"
                         : "频段以逗号分隔；LTE 不可只选 B32。")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(effectiveLockState.bandLockEnabled ? "保存频段" : "启用锁频段") {
                        if let lte = parsedLTEBands, let nr = parsedNRBands {
                            onSetBandLockEnabled?(true, lte, nr)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .disabled(!canConfigureLocks || onSetBandLockEnabled == nil || !bandDraftIsValid)
                }
            }
        }
    }

    private func bandInput(label: String, text: Binding<String>, prefix: String, supported: [Int]) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 43, alignment: .leading)
            TextField("例如 \(supported.prefix(2).map { prefix + String($0) }.joined(separator: ", "))", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .controlSize(.small)
                .disabled(!canConfigureLocks || onSetBandLockEnabled == nil)
                .help("支持：" + supported.map { prefix + String($0) }.joined(separator: "、"))
        }
    }

    private static func parseBandInput(_ raw: String, prefix: Character) -> [Int]? {
        let separators = CharacterSet(charactersIn: ",，、;； ").union(.whitespacesAndNewlines)
        let values = raw.uppercased().components(separatedBy: separators).filter { !$0.isEmpty }
        var result: [Int] = []
        for value in values {
            let number = value.first == prefix ? String(value.dropFirst()) : value
            guard let band = Int(number), band > 0 else { return nil }
            result.append(band)
        }
        return Array(Set(result)).sorted()
    }

    private var parsedLTEBands: [Int]? { Self.parseBandInput(lteBandText, prefix: "B") }
    private var parsedNRBands: [Int]? { Self.parseBandInput(nrBandText, prefix: "N") }
    private var bandDraftIsValid: Bool {
        guard let lte = parsedLTEBands, let nr = parsedNRBands, !lte.isEmpty || !nr.isEmpty,
              lte.allSatisfy(effectiveLockState.supportedLTEBands.contains),
              nr.allSatisfy(effectiveLockState.supportedNRBands.contains), lte != [32], nr != [29] else { return false }
        return lte.isEmpty || !Set(lte).isSubset(of: [29, 46])
    }

    private func loadBandDrafts() {
        lteBandText = effectiveLockState.lteBands.map(String.init).joined(separator: ",")
        nrBandText = effectiveLockState.nrBands.map(String.init).joined(separator: ",")
    }

    private func presentCellEditor(_ item: LockedCell?) {
        editingCellIndex = item?.index
        if let item {
            editingCellAct = item.act
            editingCellARFCN = String(item.arfcn)
            editingCellPCI = item.pci.map(String.init) ?? ""
        } else if let target = selectedCell ?? servingCell, Self.isLockableCell(target) {
            editingCellAct = target.tech == .lte ? 1 : 2
            editingCellARFCN = target.channel ?? ""
            editingCellPCI = target.pci ?? ""
        } else {
            editingCellAct = 2; editingCellARFCN = ""; editingCellPCI = ""
        }
        cellEditorPresented = true
    }

    private var cellEditorValue: LockedCell? {
        guard let arfcn = Int(editingCellARFCN.trimmingCharacters(in: .whitespaces)),
              (0...875000).contains(arfcn),
              effectiveLockState.allowsN79ARFCN || !(693335...733333).contains(arfcn) else { return nil }
        // The stock page accepts an empty PCI to mean "any PCI on this frequency".
        let pciText = editingCellPCI.trimmingCharacters(in: .whitespaces)
        let pci: Int?
        if pciText.isEmpty { pci = nil }
        else if let value = Int(pciText), (0...2000).contains(value) { pci = value }
        else { return nil }
        return LockedCell(index: editingCellIndex ?? 0, act: editingCellAct, arfcn: arfcn, pci: pci)
    }

    private var cellEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingCellIndex == nil ? "添加候选小区" : "编辑候选小区")
                .font(.system(size: 14, weight: .bold))
            Picker("网络制式", selection: $editingCellAct) {
                Text("4G LTE").tag(1)
                Text("5G NR").tag(2)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("频点 ARFCN")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                TextField("0–875000", text: $editingCellARFCN)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                Text("PCI")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.top, 4)
                TextField("0–2000", text: $editingCellPCI)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { cellEditorPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let value = cellEditorValue else { return }
                    if editingCellIndex == nil { onAddLockedCell?(value) }
                    else { onUpdateLockedCell?(value) }
                    cellEditorPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cellEditorValue == nil || !canConfigureLocks)
            }
        }
        .padding(18)
        .frame(width: 290)
    }
}

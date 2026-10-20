import SwiftUI
import FHCPECore

/// Base stations, carrier components and radio lock configuration in one scrolling page.
/// The overview carries the primary measurements; this page keeps supplemental values
/// and the cell identifiers needed to choose a lock target.
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

    /// Retained for callers that previously selected one of the two detail segments.
    /// Both values now open the same complete page.
    public var initialTab = 0
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
            SubpageBar(title: "基站与小区", onBack: onBack)
            detailContent
                .frame(maxHeight: .infinity, alignment: .top)
                .onAppear { loadBandDrafts() }
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

    // MARK: - Carrier components

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

    /// Values that are not already carried by the overview summary.
    private var supplementalParameters: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeading("补充射频与网络参数")
            Panel(padding: 9, spacing: 7) {
                HStack(spacing: 8) {
                    StatCell(label: "发射功率", value: FieldFormat.dbm(data.radio.power),
                             valueFont: .system(size: 11.5, weight: .bold).monospacedDigit())
                }
                if reportedValue(data.radio.scs) != nil || reportedValue(data.radio.mimo) != nil {
                    HStack(spacing: 8) {
                        if let scs = reportedValue(data.radio.scs) {
                            StatCell(label: "SCS", value: scs,
                                     valueFont: .system(size: 11.5, weight: .bold).monospacedDigit())
                        }
                        if let mimo = reportedValue(data.radio.mimo) {
                            StatCell(label: "MIMO", value: mimo,
                                     valueFont: .system(size: 11.5, weight: .bold).monospacedDigit())
                        }
                    }
                }
            }
        }
    }

    private func reportedValue(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != "-", value != "—" else { return nil }
        return value
    }

    private var servingCell: CellRecord? {
        data.isLive ? cells.first { $0.state == .serving } : nil
    }

    // MARK: - Base stations and cells

    private var detailContent: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 9) {
                carrierAggregation
                supplementalParameters
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
        guard data.isLive, let selection else { return nil }
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
        let rsrpColor = neighborSignalColor(rsrpNum)
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .frame(width: 58, alignment: .leading)

                // PCI & ARFCN column
                VStack(alignment: .leading, spacing: 2.5) {
                    Text("PCI \(cell.pci)")
                        .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("频点 \(cell.channel ?? "—")")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .frame(width: 68, alignment: .trailing)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .trailing, spacing: 1.5) {
                        Text("SINR")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                        Text(FieldFormat.db(cell.sinr) ?? "—")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .frame(width: 68, alignment: .trailing)
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

    private func neighborSignalColor(_ rsrp: Double?) -> Color {
        guard let rsrp else { return Theme.inkMuted }
        if rsrp >= -85 { return Theme.positive }
        if rsrp >= -95 { return .accentColor }
        if rsrp >= -105 { return Theme.warning }
        return Theme.negative
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
                    if hasConfirmedLockState {
                        Toggle("锁小区", isOn: Binding(
                        get: { effectiveLockState.cellLockEnabled },
                        set: { onSetCellLockEnabled?($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!canConfigureLocks || onSetCellLockEnabled == nil ||
                              (!effectiveLockState.cellLockEnabled && lockedList.isEmpty))
                    } else {
                        Text("—").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    }
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
                        Text("已配置的锁定候选小区 (\(hasConfirmedLockState ? String(lockedList.count) : "—"))")
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
                    if !hasConfirmedLockState {
                        Text("—").font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                    } else if lockedList.isEmpty {
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

    private var hasConfirmedLockState: Bool { data.isLive && lockState != nil }

    private var canConfigureLocks: Bool {
        hasConfirmedLockState && !lockBusy && effectiveLockState.configurationBlockedReason == nil && !effectiveLockState.hasConflict
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
                    if hasConfirmedLockState {
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
                    } else {
                        Text("—").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    }
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
            editingCellPCI = item.pciWireValue
        } else if let target = selectedCell ?? servingCell, Self.isLockableCell(target) {
            editingCellAct = target.tech == .lte ? 1 : 2
            editingCellARFCN = target.channel ?? ""
            editingCellPCI = target.pci
        } else {
            editingCellAct = 2; editingCellARFCN = ""; editingCellPCI = ""
        }
        cellEditorPresented = true
    }

    private var cellEditorValue: LockedCell? {
        let rawPCI = editingCellPCI.trimmingCharacters(in: .whitespacesAndNewlines)
        let pci = rawPCI.isEmpty ? nil : Int(rawPCI)
        guard rawPCI.isEmpty || pci != nil,
              let arfcn = Int(editingCellARFCN),
              (0...875000).contains(arfcn), pci.map({ (0...2000).contains($0) }) ?? true,
              effectiveLockState.allowsN79ARFCN || !(693335...733333).contains(arfcn) else { return nil }
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
                Text("PCI（可选，留空表示任意）")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.top, 4)
                TextField("留空或 0–2000", text: $editingCellPCI)
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

import SwiftUI
import FHCPECore

struct MobileNetworkSection: View {
    let state: MobileNetworkState?
    let busy: Bool
    let onSetAirplane: (Bool) -> Void
    let onSetCellular: (Bool) -> Void
    let onSaveAntenna: (Bool, AntennaType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading("移动网络")
            Panel(padding: 10, spacing: 7) {
                if let state {
                    switchRow("飞行模式", symbol: "airplane", value: state.airplaneMode,
                              enabled: !busy, action: onSetAirplane)
                    separator
                    switchRow("蜂窝数据", symbol: "antenna.radiowaves.left.and.right",
                              value: state.cellularDataEnabled,
                              enabled: !busy && !state.cellularBlocked, action: onSetCellular)
                    if state.cellularBlocked {
                        Text(state.airplaneMode ? "飞行模式下蜂窝数据不可用" : "运营商限制了蜂窝设置")
                            .font(Theme.footnote).foregroundStyle(Theme.inkMuted)
                    }
                    separator
                    switchRow("5G NR 外置天线", symbol: "dot.radiowaves.left.and.right",
                              value: state.antennaEnabled, enabled: !busy) {
                        onSaveAntenna($0, state.antennaType ?? .automatic)
                    }
                    if state.antennaEnabled {
                        HStack {
                            Text("天线类型").font(Theme.label).foregroundStyle(Theme.inkSecondary)
                            Spacer(minLength: 0)
                            Picker("天线类型", selection: Binding(
                                get: { state.antennaType },
                                set: { if let type = $0 { onSaveAntenna(true, type) } }
                            )) {
                                if state.antennaType == nil { Text("—").tag(nil as AntennaType?) }
                                ForEach(AntennaType.allCases, id: \.self) { type in
                                    Text(type.title).tag(Optional(type))
                                }
                            }
                            .labelsHidden().pickerStyle(.menu).controlSize(.small)
                            .fixedSize().disabled(busy)
                            .accessibilityLabel("外置天线类型")
                        }
                    }
                } else {
                    ForEach(["飞行模式", "蜂窝数据", "5G NR 外置天线"], id: \.self) { title in
                        HStack {
                            Text(title).font(Theme.label)
                            Spacer(minLength: 0)
                            Text("—").foregroundStyle(Theme.inkMuted)
                        }
                    }
                }
            }
        }
    }

    private var separator: some View { Rectangle().fill(Theme.hairline).frame(height: 0.5) }

    private func switchRow(_ title: String, symbol: String, value: Bool, enabled: Bool,
                           action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkSecondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 0)
            Toggle(title, isOn: Binding(get: { value }, set: action))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(!enabled).accessibilityLabel(title)
        }
    }
}

struct NetworkServicesSection: View {
    let ddnsCount: Int?
    let portCount: Int?
    let onOpenDDNS: () -> Void
    let onOpenPorts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading("网络服务")
            Panel(padding: 4, spacing: 0) {
                row("DDNS 设置", symbol: "globe", count: ddnsCount, action: onOpenDDNS)
                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 30)
                row("端口映射", symbol: "arrow.left.arrow.right", count: portCount, action: onOpenPorts)
            }
        }
    }

    private func row(_ title: String, symbol: String, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary).frame(width: 18)
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Text(count.map(String.init) ?? "—")
                    .font(Theme.footnote.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 6).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(count.map { "\($0) 条" } ?? "未读取")")
    }
}

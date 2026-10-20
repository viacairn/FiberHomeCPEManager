import SwiftUI
import FHCPECore

struct MobileNetworkSection: View {
    let state: MobileNetworkState?
    let busy: Bool
    let onSetAirplane: (Bool) -> Void
    let onSetCellular: (Bool) -> Void
    let onSaveAntenna: (Bool, AntennaType) -> Void
    @State private var antennaMenuOpen = false

    private enum AntennaOption: Hashable {
        case off
        case mode(AntennaType)

        var title: String {
            switch self {
            case .off: "关闭"
            case .mode(let type): type.title
            }
        }
    }

    private static let antennaOptions: [AntennaOption] = [
        .off,
        .mode(.automatic),
        .mode(.n41),
        .mode(.n78n77)
    ]

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
                    antennaRow(state: state)
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
        .onChange(of: busy) { _, busy in
            if busy { antennaMenuOpen = false }
        }
        .onChange(of: state) { _, _ in antennaMenuOpen = false }
        .onDisappear { antennaMenuOpen = false }
    }

    private var separator: some View { Rectangle().fill(Theme.hairline).frame(height: 0.5) }

    private func selectedAntennaOption(for state: MobileNetworkState) -> AntennaOption? {
        guard state.antennaEnabled else { return .off }
        guard let type = state.antennaType else { return nil }
        return .mode(type)
    }

    private func antennaRow(state: MobileNetworkState) -> some View {
        let current = selectedAntennaOption(for: state)
        return HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 16)
            Text("5G NR 外置天线")
                .font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                guard !busy else { return }
                antennaMenuOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(current?.title ?? "—")
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
            .disabled(busy)
            .popover(isPresented: $antennaMenuOpen, arrowEdge: .bottom) {
                VStack(spacing: 2) {
                    ForEach(Self.antennaOptions, id: \.self) { option in
                        Button {
                            antennaMenuOpen = false
                            guard !busy, current != option else { return }
                            switch option {
                            case .off:
                                onSaveAntenna(false, state.antennaType ?? .automatic)
                            case .mode(let type):
                                onSaveAntenna(true, type)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(option.title).font(.system(size: 11))
                                Spacer(minLength: 0)
                                if current == option {
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
                        .disabled(busy)
                        .accessibilityValue(current == option ? "已选择" : "")
                    }
                }
                .padding(6)
            }
            .accessibilityLabel("5G NR 外置天线：\(current?.title ?? "—")")
        }
        .frame(height: Theme.inlineControlRowHeight)
    }

    private func switchRow(_ title: String, symbol: String, value: Bool, enabled: Bool,
                           action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkSecondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 0)
            Toggle(title, isOn: Binding(get: { value }, set: { action($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(!enabled).accessibilityLabel(title)
        }
        .frame(height: Theme.inlineControlRowHeight)
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

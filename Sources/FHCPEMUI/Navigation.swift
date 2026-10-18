import SwiftUI

/// Whether the Liquid Glass material may be used. Defaults to true on macOS 26+; the
/// offscreen layout renderer and "Reduce transparency" both turn it off so the capsule
/// geometry stays deterministic and text contrast never depends on the material.
private struct GlassEnabledKey: EnvironmentKey {
    static let defaultValue = true
}
public extension EnvironmentValues {
    var fhcpemGlassEnabled: Bool {
        get { self[GlassEnabledKey.self] }
        set { self[GlassEnabledKey.self] = newValue }
    }
}

/// Capsule segmented control used by secondary pages such as `CellularDetailPage`.
public struct WideTabBar: View {
    public struct Item: Identifiable, Hashable {
        public let id: Int
        public let title: String
        public init(id: Int, title: String) { self.id = id; self.title = title }
    }

    public let items: [Item]
    @Binding public var selection: Int
    @Namespace private var namespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.fhcpemGlassEnabled) private var glassEnabled

    public init(items: [Item], selection: Binding<Int>) {
        self.items = items; self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                let selected = item.id == selection
                Button {
                    withAnimation(.smooth(duration: 0.22)) { selection = item.id }
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: selected ? .bold : .semibold))
                        .foregroundStyle(selected ? Color.accentColor : Theme.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    if selected {
                        selectedBackground.matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                .accessibilityValue(selected ? "已选中" : "")
            }
        }
        .padding(3)
        .background { container }
    }

    @ViewBuilder private var container: some View {
        let pill = CapsulePanelShape(maxRadius: 999)
        if #available(macOS 26.0, *), glassEnabled, !reduceTransparency {
            GlassEffectContainer(spacing: 8) {
                Color.clear.glassEffect(.regular, in: .capsule)
            }
        } else {
            pill
                .fill(Theme.panelFill)
                .overlay(pill.inset(by: 0.5).strokeBorder(Theme.panelHighlight, lineWidth: 0.8))
                .overlay(pill.strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
                .shadow(color: Theme.panelShadow, radius: 4, x: 0, y: 1)
        }
    }

    @ViewBuilder private var selectedBackground: some View {
        let pill = CapsulePanelShape(maxRadius: 999)
        if #available(macOS 26.0, *), glassEnabled, !reduceTransparency {
            pill
                .fill(.clear)
                .glassEffect(.regular.interactive().tint(Color.accentColor.opacity(0.14)), in: .capsule)
        } else {
            pill
                .fill(Color.accentColor.opacity(0.15))
                .overlay(pill.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.75))
        }
    }
}


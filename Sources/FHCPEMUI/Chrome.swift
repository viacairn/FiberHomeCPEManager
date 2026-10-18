import SwiftUI
import AppKit
import FHCPECore

/// Global chrome for the v2 layout: a 32 pt status header on top, a 52 pt floating tab bar
/// at the bottom, and the page canvas between them.
///
/// The v1 layout put navigation at the top as a capsule row and device identity at the
/// bottom as a footer. That inverted the natural reading order for a panel that drops down
/// from the menu bar: identity belongs where the eye lands first, navigation where the thumb
/// would be on a phone.

// MARK: - Sub-page bar

/// Compact bar for pushed pages: back, title, optional action.
///
/// The global header was removed by request, so drill-ins carry their own bar instead of
/// borrowing chrome from the panel.
public struct SubpageBar: View {
    public let title: String
    public let actionSymbol: String?
    public let actionLabel: String?
    public let onAction: (() -> Void)?
    public let onBack: () -> Void

    public init(title: String, actionSymbol: String? = nil, actionLabel: String? = nil,
                onAction: (() -> Void)? = nil, onBack: @escaping () -> Void) {
        self.title = title
        self.actionSymbol = actionSymbol
        self.actionLabel = actionLabel
        self.onAction = onAction
        self.onBack = onBack
    }

    public var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("返回").font(.system(size: 11.5, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.6))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("返回上一级")

                Spacer(minLength: 0)

                if let symbol = actionSymbol, let action = onAction {
                    Button(action: action) {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                            .frame(width: 26, height: 26)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.6))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(actionLabel ?? title)
                }
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: 34)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }
}

// MARK: - Bottom tab bar

/// Floating glass tab bar: icon over label, live badges on Devices and SMS.
public struct BottomGlassTabBar: View {
    public struct Item: Identifiable {
        public let id: Int
        public let title: String
        public let symbol: String
        public init(id: Int, title: String, symbol: String) {
            self.id = id; self.title = title; self.symbol = symbol
        }
    }

    public let items: [Item]
    @Binding public var selection: Int
    public let deviceCount: Int?
    public let unread: Int?

    @Namespace private var namespace

    public init(items: [Item], selection: Binding<Int>, deviceCount: Int?, unread: Int?) {
        self.items = items; self._selection = selection
        self.deviceCount = deviceCount; self.unread = unread
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                tab(item)
            }
        }
        .padding(4)
        .background { container }
        // Horizontal insets live in the bar; the shell owns the gap above and the inset
        // below, so the bar is exactly tabBarHeight tall (44 pt content + 4 pt padding).
        .padding(.horizontal, Theme.contentPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("页面导航")
    }

    private func tab(_ item: Item) -> some View {
        let selected = item.id == selection
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = item.id }
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 14, weight: selected ? .bold : .medium))
                        .frame(width: 22, height: 16)
                    if let badge = badge(for: item) {
                        Text("\(badge.count)")
                            .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(badge.highlight ? .white : Theme.inkSecondary)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(badge.highlight ? Color.accentColor : Color.primary.opacity(0.14))
                            )
                            .offset(x: 9, y: -5)
                    }
                }
                Text(item.title)
                    .font(.system(size: 9.5, weight: selected ? .bold : .semibold))
            }
            .foregroundStyle(selected ? Color.accentColor : Theme.inkSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.tabBarHeight - 8)
            .background {
                if selected {
                    CapsulePanelShape(maxRadius: 999)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(
                            CapsulePanelShape(maxRadius: 999)
                                .strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 0.6)
                        )
                        .matchedGeometryEffect(id: "bottom-tab-pill", in: namespace)
                }
            }
            .contentShape(CapsulePanelShape(maxRadius: 999))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(selected ? "已选中" : "")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func badge(for item: Item) -> (count: Int, highlight: Bool)? {
        switch item.id {
        case 1: return deviceCount.map { ($0, false) }
        case 3: return (unread ?? 0) > 0 ? (unread!, true) : nil
        default: return nil
        }
    }

    @ViewBuilder private var container: some View {
        let pill = CapsulePanelShape(maxRadius: 999)
        pill
            .fill(Theme.panelFill)
            .overlay(pill.inset(by: 0.5).strokeBorder(Theme.panelHighlight, lineWidth: 0.8))
            .overlay(pill.strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
            .shadow(color: Theme.panelShadow, radius: 6, x: 0, y: 2)
    }
}


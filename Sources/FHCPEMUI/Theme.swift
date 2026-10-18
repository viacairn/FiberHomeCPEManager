import SwiftUI
import AppKit
import FHCPECore

/// Shared visual language for the v6/v7 design: neutral materials, graphite type, one
/// system-blue functional accent, and state colour used only on tiny status dots.
///
/// Everything is expressed as a named token so pages never hard-code a fill opacity.
/// That was the main reason the earlier pass looked flat: several unrelated
/// `Color.primary.opacity(0.0x)` values with no relationship to each other.
public enum Theme {
    // MARK: Geometry

    /// Width of the four-tab popover pages (overview, devices, controls, SMS, settings).
    /// Constant by design: the popover must never resize with its content.
    public static let compactWidth: CGFloat = 350
    public static let compactHeight: CGFloat = 590
    public static let contentPadding: CGFloat = 16
    public static let tabBarHeight: CGFloat = 52
    /// Clearance under the popover arrow, so page content never collides with it. This is
    /// also the outer margin on every side of the page content: 16 pt left/right, 16 pt
    /// above the first row, 16 pt between the content and the tab bar, and 16 pt below the
    /// tab bar. Four equal sides, measured in the rendered PNGs.
    public static let topInset: CGFloat = 16
    public static let globalTitleHeight: CGFloat = 34
    /// Space between the page canvas and the floating tab bar.
    public static let tabBarGap: CGFloat = 16
    /// Space between the floating tab bar and the bottom edge of the panel.
    public static let tabBarBottomInset: CGFloat = 16
    /// Height available to the page canvas: panel minus the top inset, the gap above the
    /// tab bar, the bar itself, and the bottom inset. Keeping this explicit is what stops
    /// the old layout from overflowing by 22 pt and clipping the bar's bottom margin.
    public static var canvasHeight: CGFloat {
        compactHeight - topInset - tabBarGap - tabBarHeight - tabBarBottomInset
    }
    public static let tabBarRadius: CGFloat = 16

    /// Corner radii following concentric macOS geometry:
    /// - Window-scale surface: 16 pt
    /// - Grouped Bento panel: 12 pt continuous rounded rectangle
    /// - Inner rows / cards / banners: 8 pt continuous rounded rectangle
    /// - Interactive single-line controls, buttons, chips, and floating tab bar: Capsule
    public enum Radius {
        /// Window-scale surface (matches the measured 16 pt titlebar radius).
        public static let window: CGFloat = 16
        /// Grouped Bento panel.
        public static let panel: CGFloat = 12
        /// Inset between a panel edge and its rows; keeps the two radii concentric.
        public static let panelInset: CGFloat = 4
        /// Inset row or banner inside a panel: 12 − 4 = 8.
        public static let row: CGFloat = 8
        /// Text fields and small controls.
        public static let control: CGFloat = 6
        /// Buttons are capsules on macOS 26/27, so the visual radius is height / 2.
        public static var button: CGFloat { buttonHeight / 2 }
        public static let buttonHeight: CGFloat = 30
        /// Compact chips/tags.
        public static let chip: CGFloat = 5
    }

    /// Spacing scale. Every gap in the UI is one of these.
    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 22
        public static let xxl: CGFloat = 28
    }

    // MARK: Surfaces (White Liquid Glass)

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? dark : light
        })
    }

    /// Cool luminous backdrop that makes white liquid-glass cards and controls stand out clearly.
    public static let canvasBackdrop = dynamicColor(
        light: NSColor(srgbRed: 0.922, green: 0.938, blue: 0.965, alpha: 0.92),
        dark: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.92)
    )

    /// Crisp white liquid-glass control fill for inputs, pills, buttons, and inner cards.
    public static let surface = dynamicColor(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.90),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.11)
    )

    private static let panelTop = dynamicColor(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.94),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.13)
    )

    private static let panelBottom = dynamicColor(
        light: NSColor(srgbRed: 0.975, green: 0.982, blue: 0.995, alpha: 0.84),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.08)
    )

    /// White Liquid Glass panel fill with subtle vertical luminance gradient.
    public static var panelFill: LinearGradient {
        LinearGradient(colors: [panelTop, panelBottom],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Specular inner highlight along the top edge of glass panels.
    public static let panelHighlight = LinearGradient(
        colors: [Color.white.opacity(0.92), Color.white.opacity(0.25)],
        startPoint: .top, endPoint: .bottom)

    /// Slightly stronger fill for interactive rows on hover.
    public static let surfaceHover = dynamicColor(
        light: NSColor(srgbRed: 0.0, green: 0.42, blue: 0.88, alpha: 0.07),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.09)
    )

    /// Selected row / active filter.
    public static let surfaceSelected = Color.accentColor.opacity(0.16)

    /// Crisp separation line with higher contrast for white liquid glass.
    public static let hairline = dynamicColor(
        light: NSColor(srgbRed: 0.08, green: 0.14, blue: 0.24, alpha: 0.12),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.14)
    )

    public static let hairlineStrong = dynamicColor(
        light: NSColor(srgbRed: 0.08, green: 0.14, blue: 0.24, alpha: 0.19),
        dark: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.22)
    )

    public static let panelShadow = dynamicColor(
        light: NSColor(srgbRed: 0.06, green: 0.10, blue: 0.20, alpha: 0.055),
        dark: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.28)
    )

    // MARK: High-contrast text & state colours

    public static let inkSecondary = dynamicColor(
        light: NSColor(srgbRed: 0.20, green: 0.26, blue: 0.34, alpha: 1.0),
        dark: NSColor(srgbRed: 0.80, green: 0.84, blue: 0.90, alpha: 1.0)
    )

    public static let inkMuted = dynamicColor(
        light: NSColor(srgbRed: 0.34, green: 0.40, blue: 0.49, alpha: 1.0),
        dark: NSColor(srgbRed: 0.64, green: 0.69, blue: 0.77, alpha: 1.0)
    )

    public static let positive = dynamicColor(
        light: NSColor(srgbRed: 0.04, green: 0.54, blue: 0.30, alpha: 1.0),
        dark: NSColor.systemGreen
    )
    public static let negative = dynamicColor(
        light: NSColor(srgbRed: 0.82, green: 0.15, blue: 0.19, alpha: 1.0),
        dark: NSColor.systemRed
    )
    public static let warning = dynamicColor(
        light: NSColor(srgbRed: 0.80, green: 0.42, blue: 0.02, alpha: 1.0),
        dark: NSColor.systemOrange
    )

    // MARK: Type scale

    /// The four overview metrics.
    public static let metricValue = Font.system(size: 26, weight: .bold).monospacedDigit()
    public static let metricUnit = Font.system(size: 10.5, weight: .semibold)
    public static let metricCaption = Font.system(size: 11, weight: .semibold)
    /// Page titles ("在线设备", "设置").
    public static let pageTitle = Font.system(size: 16, weight: .bold)
    public static let sectionTitle = Font.system(size: 11.5, weight: .bold)
    public static let body = Font.system(size: 12.5, weight: .medium)
    public static let footnote = Font.system(size: 10.5, weight: .medium)
    public static let nav = Font.system(size: 12, weight: .semibold)
    public static let value = Font.system(size: 13.5, weight: .bold).monospacedDigit()
    /// Slightly smaller label/value pair used by the denser overview grid.
    public static let valueSmall = Font.system(size: 11.5, weight: .semibold).monospacedDigit()
    public static let label = Font.system(size: 10.5, weight: .medium)
    public static let rowTitle = Font.system(size: 12.5, weight: .semibold)
    public static let rowSubtitle = Font.system(size: 10.5, weight: .medium)

    // MARK: Motion

    /// Interaction snap: tab changes, selection, expansion.
    public static let snap = Animation.spring(response: 0.28, dampingFraction: 0.86)
    /// Quick feedback: hover, press.
    public static let quick = Animation.easeOut(duration: 0.12)
    /// Page transitions.
    public static let page = Animation.spring(response: 0.32, dampingFraction: 0.9)
}

// MARK: - Components

/// Concentric rounded rectangle shape for multi-row Bento cards and panels.
public struct CapsulePanelShape: InsettableShape {
    public var maxRadius: CGFloat
    public var insetAmount: CGFloat = 0
    public init(maxRadius: CGFloat = Theme.Radius.panel) { self.maxRadius = maxRadius }

    public func inset(by amount: CGFloat) -> CapsulePanelShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    public func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let halfMinor = min(rect.width, rect.height) / 2
        return Path(roundedRect: rect,
                    cornerRadius: min(halfMinor, maxRadius),
                    style: maxRadius >= halfMinor ? .circular : .continuous)
    }
}

/// White Liquid Glass grouped container: luminous white glass fill, inner specular rim,
/// crisp outer hairline, and subtle elevation shadow.
public struct Panel<Content: View>: View {
    public var padding: CGFloat
    public var spacing: CGFloat
    @ViewBuilder public let content: () -> Content

    public init(padding: CGFloat = Theme.Space.m, spacing: CGFloat = Theme.Space.m,
                @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.spacing = spacing; self.content = content
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panelFill, in: shape)
            .overlay(
                shape.inset(by: 0.5).strokeBorder(Theme.panelHighlight, lineWidth: 0.8)
            )
            .overlay(
                shape.strokeBorder(Theme.hairline, lineWidth: 0.75)
            )
            .shadow(color: Theme.panelShadow, radius: 5, x: 0, y: 2)
    }
}

/// Section heading used above a `Panel`.
public struct PanelHeading: View {
    public let title: String
    public var trailing: String?
    public init(_ title: String, trailing: String? = nil) {
        self.title = title; self.trailing = trailing
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Text(title)
                .font(Theme.sectionTitle)
                .foregroundStyle(Color.primary.opacity(0.86))
                .tracking(0.2)
            Spacer(minLength: Theme.Space.xs)
            if let trailing {
                Text(trailing).font(Theme.footnote).foregroundStyle(Theme.inkMuted)
            }
        }
    }
}

/// Status dot. Colour is always paired with a text label, so meaning never depends on
/// colour alone (the spec's accessibility requirement).
public struct StatusDot: View {
    public enum Tone { case positive, negative, warning, neutral, accent }
    public let tone: Tone
    public var size: CGFloat = 7
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    public init(_ tone: Tone, size: CGFloat = 7) { self.tone = tone; self.size = size }

    public var body: some View {
        marker
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Colour alone must not carry meaning: when "differentiate without colour" is on, a
    /// healthy state stays a circle while every problem state becomes a diamond.
    @ViewBuilder private var marker: some View {
        if differentiate, tone == .negative || tone == .warning {
            DiamondShape().fill(color)
        } else {
            Circle().fill(color)
        }
    }

    private var color: Color {
        switch tone {
        case .positive: Theme.positive
        case .negative: Theme.negative
        case .warning: Theme.warning
        case .neutral: Theme.inkMuted
        case .accent: .accentColor
        }
    }
}

/// Diamond marker for non-colour status signalling.
public struct DiamondShape: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

public struct SignalBars: View {
    public let level: Int?          // nil = unknown, 0...4 = filled bars
    public var activeColor: Color = .primary
    public var inactiveColor: Color = .secondary.opacity(0.28)
    public var barWidth: CGFloat = 3
    public var gap: CGFloat = 2.5
    public var unit: CGFloat = 1.6

    public init(level: Int?, activeColor: Color = .primary,
                inactiveColor: Color = .secondary.opacity(0.28),
                barWidth: CGFloat = 3, gap: CGFloat = 2.5, unit: CGFloat = 1.6) {
        self.level = level; self.activeColor = activeColor; self.inactiveColor = inactiveColor
        self.barWidth = barWidth; self.gap = gap; self.unit = unit
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(0..<4, id: \.self) { index in
                barView(index)
            }
        }
        .frame(height: unit * 4 + barWidth, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    /// Unknown readings are drawn as outlines so they cannot be confused with "no signal",
    /// which is four dimmed solid bars.
    @ViewBuilder private func barView(_ index: Int) -> some View {
        let height = unit * CGFloat(index + 1) + barWidth
        let shape = RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
        if level == nil {
            shape
                .strokeBorder(inactiveColor, lineWidth: 1)
                .frame(width: barWidth, height: height)
        } else {
            shape
                .fill(isActive(index) ? activeColor : inactiveColor)
                .frame(width: barWidth, height: height)
        }
    }

    private func isActive(_ index: Int) -> Bool {
        guard let level else { return false }
        return index < level
    }

    private var accessibilityText: String {
        guard let level else { return "信号未知" }
        return level == 0 ? "无信号" : "信号 \(level) 档"
    }
}


/// Value + raised unit + caption underneath, centre-aligned.
public struct MetricCell: View {
    public let value: String?
    public let unit: String?
    public let caption: String
    public var valueFont: Font = Theme.metricValue
    public var accessibilityValue: String?

    public init(value: String?, unit: String?, caption: String,
                valueFont: Font = Theme.metricValue, accessibilityValue: String? = nil) {
        self.value = value; self.unit = unit; self.caption = caption
        self.valueFont = valueFont; self.accessibilityValue = accessibilityValue
    }

    public var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .font(valueFont)
                    .foregroundStyle(value == nil ? Theme.inkMuted : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
                if let unit, value != nil {
                    Text(unit)
                        .font(Theme.metricUnit)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            Text(caption)
                .font(Theme.metricCaption)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(accessibilityValue ?? [value, unit].compactMap { $0 }.joined(separator: " "))
    }
}

/// Small label/value stack used by the cellular grids.
public struct StatCell: View {
    public let label: String
    public let value: String?
    public var valueFont: Font = Theme.value
    public var alignment: HorizontalAlignment = .center

    public init(label: String, value: String?, valueFont: Font = Theme.value, alignment: HorizontalAlignment = .center) {
        self.label = label; self.value = value; self.valueFont = valueFont; self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label).font(Theme.label).foregroundStyle(Theme.inkSecondary)
            Text(value ?? "—")
                .font(valueFont)
                .foregroundStyle(value == nil ? Theme.inkMuted : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

/// Amber "适配中" badge. A small inline label, never a giant warning banner.
public struct AdaptingBadge: View {
    public var text: String
    public init(_ text: String = "适配中") { self.text = text }
    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.warning.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.warning.opacity(0.35), lineWidth: 0.5))
            .accessibilityLabel("功能适配中")
    }
}

/// Quiet secondary footnote used for capability explanations.
public struct QuietNote: View {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(Theme.footnote)
            .foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Signal quality

/// Five-segment meter used for RSRP / RSRQ / SINR.
public struct LevelMeter: View {
    public let level: Int
    public let tint: Color
    public init(level: Int, tint: Color) {
        self.level = level; self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < level ? tint : Color.primary.opacity(0.16))
                    .frame(width: 4, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Thresholds for the three RF readings, using the values carriers publish as
/// "good / fair / poor" for 5G NR.
public enum SignalQuality {
    public static func rsrp(_ value: Double?) -> (level: Int, tint: Color) {
        guard let value else { return (0, .secondary) }
        if value >= -80 { return (5, Theme.positive) }
        if value >= -90 { return (4, Theme.positive) }
        if value >= -100 { return (3, Theme.warning) }
        if value >= -110 { return (2, Theme.warning) }
        return (1, Theme.negative)
    }

    public static func rsrq(_ value: Double?) -> (level: Int, tint: Color) {
        guard let value else { return (0, .secondary) }
        if value >= -10 { return (5, Theme.positive) }
        if value >= -15 { return (4, Theme.warning) }
        if value >= -20 { return (2, Theme.negative) }
        return (1, Theme.negative)
    }

    public static func sinr(_ value: Double?) -> (level: Int, tint: Color) {
        guard let value else { return (0, .secondary) }
        if value >= 20 { return (5, Theme.positive) }
        if value >= 13 { return (4, Theme.positive) }
        if value >= 7 { return (3, Theme.warning) }
        if value >= 0 { return (2, Theme.warning) }
        return (1, Theme.negative)
    }
}

// MARK: - Status banner

/// Firmware error (or confirmation) with a one-click copy of the original text.
public struct StatusBanner: View {
    public enum Tone { case error, success, info }

    public let text: String
    public let tone: Tone

    public init(text: String, tone: Tone) {
        self.text = text; self.tone = tone
    }

    private var tint: Color {
        switch tone {
        case .error: Theme.negative
        case .success: Theme.positive
        case .info: Theme.inkSecondary
        }
    }

    private var symbol: String {
        switch tone {
        case .error: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .info: "info.circle"
        }
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制错误原文")
            .accessibilityLabel("复制提示内容")
        }
        .foregroundStyle(tone == .info ? AnyShapeStyle(Theme.inkSecondary) : AnyShapeStyle(tint))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: shape)
        .background(tint.opacity(0.12), in: shape)
        .overlay(
            shape.strokeBorder(tint.opacity(tone == .info ? 0.22 : 0.42), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Native material

/// The panel and the bottom bar use the same material as the native context menu, so the
/// main surface and the right-click menu share one background/vibrancy language.
///
/// SwiftUI has no direct equivalent of `NSVisualEffectView` with `.behindWindow` blending;
/// wrapping it keeps the window transparent and lets macOS do the blurring.
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public init(material: NSVisualEffectView.Material = .menu) { self.material = material }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.state = .active
    }
}

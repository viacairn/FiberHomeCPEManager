import SwiftUI
import FHCPECore

/// Shared text entry styling for the connection form.
///
/// A soft surface with a hairline border that brightens to the accent colour on focus.
/// Stock `.roundedBorder` reads as an unstyled AppKit control next to the rest of the UI.
struct GlassField: View {
    @Binding var text: String
    let placeholder: String
    var secure = false
    @FocusState.Binding var focus: ConnectionField?
    let tag: ConnectionField

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.surface, in: CapsulePanelShape(maxRadius: 999))
        .overlay(
            CapsulePanelShape(maxRadius: 999)
                .strokeBorder(focus == tag ? Color.accentColor.opacity(0.65) : Theme.hairline,
                              lineWidth: focus == tag ? 1 : 0.5)
        )
        .focused($focus, equals: tag)
    }
}

/// Identifies which connection field owns focus.
enum ConnectionField: Hashable { case address, username, password }

/// Primary action. macOS 27 draws buttons as capsules, so the radius is height / 2.
///
/// A `ButtonStyle` must never apply `.buttonStyle(...)` to its own label: doing so made the
/// button vanish from the render tree entirely (no `AXButton` existed, so connect was
/// unreachable). The glass look is produced with a shape and material instead.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.fhcpemGlassEnabled) private var glassEnabled
        @State private var hovering = false

        private var pressed: Bool { configuration.isPressed }

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Radius.buttonHeight)
                .background { fill }
                .contentShape(Capsule())
                .opacity(pressed ? 0.88 : 1)
                .scaleEffect(pressed ? 0.985 : 1)
                .animation(Theme.quick, value: pressed)
                .animation(Theme.quick, value: hovering)
                .onHover { hovering = $0 }
        }

        @ViewBuilder private var fill: some View {
            let shape = Capsule()
            if enabled {
                if #available(macOS 26.0, *), glassEnabled, !reduceTransparency {
                    shape
                        .fill(Color.accentColor.opacity(hovering ? 1 : 0.94))
                        .glassEffect(.regular.tint(Color.accentColor).interactive(), in: shape)
                        .shadow(color: Color.accentColor.opacity(0.22), radius: 3, y: 1)
                } else {
                    shape
                        .fill(Color.accentColor.opacity(hovering ? 1 : 0.94))
                        .shadow(color: Color.accentColor.opacity(0.18), radius: 2, y: 1)
                }
            } else {
                shape.fill(Color.primary.opacity(0.09))
            }
        }
    }
}


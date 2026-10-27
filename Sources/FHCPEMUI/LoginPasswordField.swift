import SwiftUI
import FHCPECore

/// Native password entry shares one normalized binding in secure and revealed modes.
struct LoginPasswordField: View {
    @Binding var text: String
    let secure: Bool
    @FocusState.Binding var focus: ConnectionField?
    let onSubmit: () -> Void

    private var normalizedText: Binding<String> {
        Binding(get: { text }, set: { text = PasswordInput.halfWidth($0) })
    }

    var body: some View {
        Group {
            if secure {
                SecureField("请输入管理员密码", text: normalizedText)
            } else {
                TextField("请输入管理员密码", text: normalizedText)
            }
        }
        .textFieldStyle(.plain)
        .textContentType(.password)
        .font(.system(size: 11.5))
        .focused($focus, equals: .password)
        .accessibilityLabel("密码")
        .onSubmit(onSubmit)
    }
}

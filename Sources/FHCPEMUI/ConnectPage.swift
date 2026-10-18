import SwiftUI
import FHCPECore

/// First-run connection page. No tabs, no model/IP header, no fake live readings.
public struct ConnectPage: View {
    @Binding public var address: String
    @Binding public var username: String
    @Binding public var password: String
    @Binding public var savePassword: Bool
    public let busy: Bool
    public let error: String?
    public let onConnect: () -> Void
    public let onDetectGateway: () -> Void

    public init(address: Binding<String>, username: Binding<String>, password: Binding<String>,
                savePassword: Binding<Bool>, busy: Bool, error: String?,
                onConnect: @escaping () -> Void,
                onDetectGateway: @escaping () -> Void) {
        self._address = address; self._username = username; self._password = password
        self._savePassword = savePassword
        self.busy = busy; self.error = error
        self.onConnect = onConnect; self.onDetectGateway = onDetectGateway
    }

    @FocusState private var focus: ConnectionField?

    /// A greyed-out button reads as "broken" rather than "password required". The button
    /// stays enabled and, when the password is missing, moves focus there and says why.
    ///
    /// Full-width punctuation is blocked before any request: a Chinese IME turning the
    /// input into full-width forms can consume authentication attempts and trigger
    /// the firmware's one-minute lockout.
    private func submit() {
        if let issue = PasswordInput.issue(in: password) {
            focus = .password
            emptyPasswordHint = (issue == .empty)
            showPasswordIssue = (issue != .empty)
            return
        }
        emptyPasswordHint = false
        showPasswordIssue = false
        onConnect()
    }

    @State private var emptyPasswordHint = false
    @State private var showPasswordIssue = false
    @State private var revealPassword = false

    /// Show full-width warnings as soon as they are typed; other issues appear on submit.
    private var visiblePasswordIssue: PasswordInputIssue? {
        guard let issue = PasswordInput.issue(in: password) else { return nil }
        if case .fullWidth = issue { return issue }
        return showPasswordIssue && issue != .empty ? issue : nil
    }

    /// Strips `http://`, any path, and whitespace so the field only ever holds a host.
    static func cleanAddress(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where value.lowercased().hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        return value
    }

    /// The message under the form: an explicit empty-password hint wins over the network
    /// reminder, and a connection error wins over both.
    private var statusLine: (text: String, isError: Bool) {
        if let error { return (error, true) }
        if emptyPasswordHint { return ("请输入密码后再连接", true) }
        return ("请连接到设备所在的局域网", false)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // The block is centred rather than pinned to the top: a 350×590 panel with a
            // form at the very top and a third of the page empty read as unfinished.
            VStack(spacing: Theme.Space.l) {
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 42, height: 42)
                        Image(systemName: "wifi.router.fill")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text("FiberHome CPE Manager")
                        .font(.system(size: 16, weight: .semibold))
                    Text("烽火 5G CPE 原生状态栏管理工具")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Panel(padding: 14, spacing: 12) {
                    field("设备 IP", placeholder: "192.168.8.1", text: $address, tag: .address,
                          accessory: {
                              Button(action: onDetectGateway) {
                                  HStack(spacing: 3) {
                                      Image(systemName: "arrow.down.doc")
                                          .font(.system(size: 9, weight: .semibold))
                                      Text("导入网关")
                                          .font(.system(size: 10, weight: .medium))
                                  }
                              }
                              .buttonStyle(.plain)
                              .foregroundStyle(.tint)
                              .accessibilityLabel("导入网关地址")
                          }) {
                        // Accept a pasted URL but keep the field IP-only.
                        let stripped = Self.cleanAddress(address)
                        if stripped != address { address = stripped }
                    }
                    field("账号", placeholder: "admin", text: $username, tag: .username)

                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: 6) {
                            Text("密码")
                                .font(Theme.label)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Toggle(isOn: $savePassword) {
                                Text("保存密码")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.mini)
                            .fixedSize()
                            .accessibilityLabel("保存密码")
                        }
                        ZStack(alignment: .trailing) {
                            GlassField(text: $password, placeholder: "请输入管理员密码",
                                       secure: !revealPassword, focus: $focus, tag: .password)
                                .onSubmit { submit() }
                            Button {
                                revealPassword.toggle()
                            } label: {
                                Image(systemName: revealPassword ? "eye.slash" : "eye")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 3)
                            .accessibilityLabel(revealPassword ? "隐藏密码" : "显示密码")
                        }
                        if let issue = visiblePasswordIssue {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 9.5))
                                Text(issue.message)
                                    .font(.system(size: 9.5))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                if case .fullWidth = issue {
                                    Button("改为半角") {
                                        password = PasswordInput.halfWidth(password)
                                        showPasswordIssue = false
                                        focus = .password
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("把密码中的全角字符改为半角")
                                }
                            }
                            .foregroundStyle(Theme.negative)
                        }
                    }

                    Button(action: submit) {
                        HStack(spacing: 6) {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "正在连接" : "连接")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
                    .keyboardShortcut(.defaultAction)
                }

                HStack(spacing: 5) {
                    Image(systemName: statusLine.isError ? "exclamationmark.circle" : "info.circle")
                        .font(.system(size: 9.5))
                    Text(statusLine.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .font(.system(size: 10))
                .foregroundStyle(statusLine.isError ? AnyShapeStyle(Theme.negative) : AnyShapeStyle(.tertiary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Theme.snap, value: statusLine.text)
                .textSelection(.enabled)

                if !statusLine.isError {
                    Text("管理地址通常印在设备背面，只需填 IP，无需 http://")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.contentPadding)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .onChange(of: error) { _, newValue in
            if newValue != nil { focus = .password }
        }
        .onChange(of: password) { _, newValue in
            if showPasswordIssue { showPasswordIssue = false }
            if !newValue.isEmpty { emptyPasswordHint = false }
        }
    }

    /// One labelled field with consistent spacing.
    @ViewBuilder private func field<Accessory: View>(
        _ label: String, placeholder: String, text: Binding<String>,
        tag: ConnectionField, secure: Bool = false, submit: Bool = false,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        onChange: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: 6) {
                Text(label).font(Theme.label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory()
            }
            GlassField(text: text, placeholder: placeholder, secure: secure,
                       focus: $focus, tag: tag)
                .onSubmit { if submit { self.submit() } }
                .onChange(of: text.wrappedValue) { _, _ in onChange?() }
        }
    }
}

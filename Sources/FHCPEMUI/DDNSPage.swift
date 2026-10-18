import SwiftUI
import FHCPECore

public struct DDNSPage: View {
    public let entries: [DDNSEntry]
    public let wans: [WANConnectionRef]
    public let busy: Bool
    public let status: String?
    public let statusIsError: Bool
    public let onBack: () -> Void
    public let onReload: () -> Void
    public let onSave: (DDNSEntry?, DDNSInput) async throws -> Void
    public let onDelete: (DDNSEntry) async throws -> Void
    public let onToggle: (DDNSEntry, Bool) async throws -> Void

    public init(entries: [DDNSEntry], wans: [WANConnectionRef], busy: Bool,
                status: String?, statusIsError: Bool,
                onBack: @escaping () -> Void, onReload: @escaping () -> Void,
                onSave: @escaping (DDNSEntry?, DDNSInput) async throws -> Void,
                onDelete: @escaping (DDNSEntry) async throws -> Void,
                onToggle: @escaping (DDNSEntry, Bool) async throws -> Void) {
        self.entries = entries; self.wans = wans; self.busy = busy
        self.status = status; self.statusIsError = statusIsError
        self.onBack = onBack; self.onReload = onReload
        self.onSave = onSave; self.onDelete = onDelete; self.onToggle = onToggle
    }

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let entry: DDNSEntry?
    }

    @State private var editorTarget: EditorTarget?
    @State private var rowError: String?

    public var body: some View {
        VStack(spacing: 0) {
            SubpageBar(title: "DDNS 设置", actionSymbol: "plus", actionLabel: "添加 DDNS",
                       onAction: { editorTarget = EditorTarget(entry: nil) }, onBack: onBack)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if entries.isEmpty {
                        emptyState
                    } else {
                        Panel(padding: 5, spacing: 0) {
                            ForEach(entries) { entry in
                                row(entry)
                                if entry.id != entries.last?.id {
                                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                                        .padding(.leading, 8)
                                }
                            }
                        }
                    }
                    if let rowError {
                        StatusBanner(text: rowError, tone: .error)
                    }
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.top, 8)
                .padding(.bottom, Theme.Space.m)
            }
            .scrollIndicators(.automatic)
            if let status {
                StatusBanner(text: status, tone: statusIsError ? .error : .success)
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.bottom, 8)
            }
        }
        .sheet(item: $editorTarget) { target in
            DDNSForm(entry: target.entry, wans: wans, onSave: onSave)
        }
        .onChange(of: entries) { _, _ in rowError = nil }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.inkMuted)
            Text("尚未配置 DDNS")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text("点击右上角 + 添加一条动态域名")
                .font(.system(size: 10))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func row(_ entry: DDNSEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                editorTarget = EditorTarget(entry: entry)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.hostname)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(entry.providerTitle) · \(entry.wan.title)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑 DDNS \(entry.hostname)")

            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { value in mutate { try await onToggle(entry, value) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(busy)
            .accessibilityLabel("DDNS \(entry.hostname) 启用")

            Button {
                mutate { try await onDelete(entry) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("删除 DDNS")
            .accessibilityLabel("删除 DDNS \(entry.hostname)")
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 38)
    }

    private func mutate(_ action: @escaping () async throws -> Void) {
        rowError = nil
        Task { @MainActor in
            do { try await action(); onReload() }
            catch { rowError = error.localizedDescription }
        }
    }
}

private struct DDNSForm: View {
    let entry: DDNSEntry?
    let wans: [WANConnectionRef]
    let onSave: (DDNSEntry?, DDNSInput) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var wanID: String
    @State private var providerChoice: String
    @State private var customProvider: String
    @State private var hostname: String
    @State private var username: String
    @State private var password: String
    @State private var enabled: Bool
    @State private var saving = false
    @State private var saveError: String?

    init(entry: DDNSEntry?, wans: [WANConnectionRef],
         onSave: @escaping (DDNSEntry?, DDNSInput) async throws -> Void) {
        self.entry = entry; self.wans = wans; self.onSave = onSave
        let known = DDNSInput.providers.contains(entry?.provider ?? "")
        self._wanID = State(initialValue: entry?.wan.id ?? wans.first?.id ?? "")
        self._providerChoice = State(initialValue: known ? (entry?.provider ?? "dyndns") : (entry == nil ? "dyndns" : "custom"))
        self._customProvider = State(initialValue: known ? "" : (entry?.provider ?? ""))
        self._hostname = State(initialValue: entry?.hostname ?? "")
        self._username = State(initialValue: entry?.username ?? "")
        self._password = State(initialValue: entry?.password ?? "")
        self._enabled = State(initialValue: entry?.enabled ?? true)
    }

    private var selectedWAN: WANConnectionRef? {
        wans.first { $0.id == wanID } ?? entry?.wan ?? wans.first
    }

    private var provider: String {
        providerChoice == "custom" ? customProvider : providerChoice
    }

    private var input: DDNSInput? {
        guard let wan = selectedWAN else { return nil }
        return DDNSInput(wan: wan, provider: provider, hostname: hostname,
                         username: username, password: password, enabled: enabled)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry == nil ? "添加 DDNS" : "编辑 DDNS")
                .font(.system(size: 14, weight: .bold))
            if wans.count > 1 {
                field("WAN") {
                    Picker("WAN", selection: $wanID) {
                        ForEach(wans) { wan in Text(wan.title).tag(wan.id) }
                    }
                    .labelsHidden().disabled(entry != nil || saving)
                }
            }
            field("服务商") {
                Picker("服务商", selection: $providerChoice) {
                    Text("DynDNS").tag("dyndns")
                    Text("TZO").tag("tzo")
                    Text("oray.com").tag("ORAY")
                    Text("No-IP.com").tag("No-IP.com")
                    Text("其他").tag("custom")
                }
                .labelsHidden().disabled(saving)
            }
            if providerChoice == "custom" {
                PanelTextField(text: $customProvider, placeholder: "服务商地址")
                    .disabled(saving)
            }
            field("域名 / 主机名") {
                PanelTextField(text: $hostname, placeholder: "home.example.com").disabled(saving)
            }
            field("用户名") {
                PanelTextField(text: $username, placeholder: "DDNS 用户名").disabled(saving)
            }
            field("密码") {
                PanelTextField(text: $password, placeholder: "DDNS 密码", secure: true).disabled(saving)
            }
            Toggle("启用此条 DDNS", isOn: $enabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .disabled(saving)
            if let saveError = saveError ?? input?.validationError {
                StatusBanner(text: saveError, tone: .error)
            }
            HStack(spacing: 8) {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Spacer(minLength: 0)
                if saving { ProgressView().controlSize(.mini) }
                Button {
                    save()
                } label: {
                    Text(saving ? "正在保存…" : "保存").frame(width: 92)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(saving || input?.validationError != nil)
            }
        }
        .padding(Theme.contentPadding)
        .frame(width: Theme.compactWidth - 32)
        .interactiveDismissDisabled(saving)
    }

    @ViewBuilder private func field<Content: View>(_ label: String,
                                                   @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            content()
        }
    }

    private func save() {
        guard let input, input.validationError == nil, !saving else { return }
        saving = true; saveError = nil
        Task { @MainActor in
            defer { saving = false }
            do { try await onSave(entry, input); dismiss() }
            catch { saveError = error.localizedDescription }
        }
    }
}

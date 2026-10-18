import SwiftUI
import FHCPECore

public struct DDNSPage: View {
    public let entries: [DDNSEntry]
    public let wans: [WANConnectionRef]
    public let busy: Bool
    public let isLive: Bool
    public let status: String?
    public let statusIsError: Bool
    public let onBack: () -> Void
    public let onReload: () -> Void
    public let onSave: (DDNSEntry?, DDNSInput) async throws -> Void
    public let onDelete: (DDNSEntry) async throws -> Void
    public let onToggle: (DDNSEntry, Bool) async throws -> Void

    public init(entries: [DDNSEntry], wans: [WANConnectionRef], busy: Bool,
                isLive: Bool = true, status: String?, statusIsError: Bool,
                onBack: @escaping () -> Void, onReload: @escaping () -> Void,
                onSave: @escaping (DDNSEntry?, DDNSInput) async throws -> Void,
                onDelete: @escaping (DDNSEntry) async throws -> Void,
                onToggle: @escaping (DDNSEntry, Bool) async throws -> Void) {
        self.entries = entries; self.wans = wans; self.busy = busy; self.isLive = isLive
        self.status = status; self.statusIsError = statusIsError
        self.onBack = onBack; self.onReload = onReload
        self.onSave = onSave; self.onDelete = onDelete; self.onToggle = onToggle
    }

    @State private var pageActive = true
    @State private var mutationToken: UUID?
    @State private var mutationTask: Task<Void, Never>?
    @State private var showingEditor = false
    @State private var editingID: String?
    @State private var deletingID: String?
    @State private var draft = DDNSDraft()
    @State private var rowError: String?
    @State private var formError: String?

    private var working: Bool { busy || mutationToken != nil }
    private var canWrite: Bool { isLive && pageActive && !working }
    private var canOpenAction: Bool { canWrite && !showingEditor && deletingID == nil }
    private var availableWANs: [WANConnectionRef] {
        wans.filter { wan in entries.filter { $0.wan.id == wan.id }.count < 4 }
    }
    private var canAdd: Bool { canOpenAction && !availableWANs.isEmpty }
    private var editorWANs: [WANConnectionRef] { editingID == nil ? availableWANs : wans }
    private var editorInput: DDNSInput? { draft.input(wans: editorWANs) }
    private var validationError: String? {
        guard editorInput != nil else { return "未读取到可用的 WAN 连接。" }
        return draft.validationError ?? editorInput?.validationError
    }

    public var body: some View {
        VStack(spacing: 0) {
            SubpageBar(title: "DDNS 设置", actionSymbol: canAdd ? "plus" : nil,
                       actionLabel: "添加 DDNS", onAction: { presentEditor(nil) }, onBack: leavePage)
            if isLive {
                onlineContent
                if let status {
                    StatusBanner(text: status, tone: statusIsError ? .error : .success)
                        .padding(.horizontal, Theme.contentPadding)
                        .padding(.bottom, 8)
                }
            } else {
                AdvancedSettingsDisconnectedState()
            }
        }
        .sheet(isPresented: editorPresentation, onDismiss: clearEditor) {
            if isLive {
                DDNSForm(draft: $draft, wans: editorWANs, editing: editingID != nil,
                         locked: working, saving: mutationToken != nil,
                         error: formError ?? validationError,
                         canSave: canWrite && editorInput != nil && validationError == nil,
                         onCancel: clearEditor, onSave: saveEditor)
            }
        }
        .confirmationDialog("删除 DDNS？", isPresented: deletionPresentation,
                            titleVisibility: .visible, presenting: deletingID) { id in
            Button("删除", role: .destructive) { confirmDelete(id) }
                .disabled(!canWrite)
            Button("取消", role: .cancel) { deletingID = nil }
        } message: { _ in
            Text("将删除这条 DDNS 配置。")
        }
        .onAppear {
            pageActive = isLive
            if !isLive { invalidatePage() }
        }
        .onChange(of: isLive) { _, live in
            invalidatePage()
            pageActive = live
        }
        .onChange(of: entries) { _, _ in
            rowError = nil
            if let editingID, !entries.contains(where: { $0.id == editingID }) { clearEditor() }
            if let deletingID, !entries.contains(where: { $0.id == deletingID }) { self.deletingID = nil }
        }
        .onChange(of: wans) { _, _ in
            if showingEditor, !editorWANs.contains(where: { $0.id == draft.wanID }) { clearEditor() }
            deletingID = nil
        }
        .onDisappear { invalidatePage() }
    }

    private var editorPresentation: Binding<Bool> {
        Binding(get: { isLive && showingEditor }, set: { if !$0 { clearEditor() } })
    }

    private var deletionPresentation: Binding<Bool> {
        Binding(get: { isLive && deletingID != nil }, set: { if !$0 { deletingID = nil } })
    }

    private var onlineContent: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                if wans.isEmpty {
                    Text(busy ? "正在读取 WAN 连接…" : "未读取到可用的 WAN 连接。")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                }
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
                if let rowError { StatusBanner(text: rowError, tone: .error) }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 8)
            .padding(.bottom, Theme.Space.m)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.inkMuted)
            Text("尚未配置 DDNS")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            if !availableWANs.isEmpty {
                Text("点击右上角 + 添加一条动态域名")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func knowsWAN(_ entry: DDNSEntry) -> Bool {
        wans.contains { $0.id == entry.wan.id }
    }

    private func row(_ entry: DDNSEntry) -> some View {
        HStack(spacing: 8) {
            Button { presentEditor(entry) } label: {
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
            .disabled(!canOpenAction || !knowsWAN(entry))
            .accessibilityLabel("编辑 DDNS \(entry.hostname)")

            Toggle("DDNS 启用", isOn: Binding(
                get: { entry.enabled },
                set: { value in
                    guard canOpenAction, knowsWAN(entry) else { return }
                    mutate(fromEditor: false) { try await onToggle(entry, value) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!canOpenAction || !knowsWAN(entry))
            .accessibilityLabel("DDNS \(entry.hostname) 启用")

            Button {
                guard canOpenAction, knowsWAN(entry) else { return }
                deletingID = entry.id
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpenAction || !knowsWAN(entry))
            .help("删除 DDNS")
            .accessibilityLabel("删除 DDNS \(entry.hostname)")
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 38)
    }

    private func presentEditor(_ entry: DDNSEntry?) {
        guard canOpenAction else { return }
        if let entry {
            guard knowsWAN(entry) else { return }
        } else {
            guard !availableWANs.isEmpty else { return }
        }
        editingID = entry?.id
        draft = DDNSDraft(entry: entry, wans: entry == nil ? availableWANs : wans)
        formError = nil
        showingEditor = true
    }

    private func saveEditor() {
        guard showingEditor, canWrite, let input = editorInput, validationError == nil else { return }
        let entry: DDNSEntry?
        if let editingID {
            guard let current = entries.first(where: { $0.id == editingID }), knowsWAN(current) else {
                clearEditor()
                return
            }
            entry = current
        } else { entry = nil }
        mutate(fromEditor: true) { try await onSave(entry, input) }
    }

    private func confirmDelete(_ id: String) {
        guard canWrite,
              let entry = entries.first(where: { $0.id == id }), knowsWAN(entry) else {
            self.deletingID = nil
            return
        }
        self.deletingID = nil
        mutate(fromEditor: false) { try await onDelete(entry) }
    }

    /// Every write shares this synchronous gate. The token is checked again after each
    /// suspension so completion from a dismissed or disconnected page cannot fill it.
    private func mutate(fromEditor: Bool, _ action: @escaping () async throws -> Void) {
        guard canWrite else { return }
        let token = UUID()
        mutationToken = token
        rowError = nil; formError = nil
        mutationTask = Task { @MainActor in
            do {
                guard pageActive, mutationToken == token, !Task.isCancelled else { return }
                try await action()
                guard pageActive, mutationToken == token, !Task.isCancelled else { return }
                mutationToken = nil; mutationTask = nil
                if fromEditor { clearEditor() }
                onReload()
            } catch {
                guard pageActive, mutationToken == token, !Task.isCancelled else { return }
                mutationToken = nil; mutationTask = nil
                if fromEditor { formError = error.localizedDescription }
                else { rowError = error.localizedDescription }
            }
        }
    }

    private func clearEditor() {
        showingEditor = false; editingID = nil
        draft = DDNSDraft(); formError = nil
    }

    private func invalidatePage() {
        pageActive = false; mutationToken = nil
        mutationTask?.cancel(); mutationTask = nil
        clearEditor()
        deletingID = nil; rowError = nil
    }

    private func leavePage() {
        invalidatePage()
        onBack()
    }
}

private struct DDNSDraft {
    var wanID = ""
    var providerChoice = "dyndns"
    var customProvider = ""
    var hostname = ""
    var username = ""
    var password = ""
    var enabled = false

    init(entry: DDNSEntry? = nil, wans: [WANConnectionRef] = []) {
        wanID = entry?.wan.id ?? wans.first?.id ?? ""
        if let entry {
            let known = DDNSInput.providers.contains(entry.provider)
            providerChoice = known ? entry.provider : "Others"
            customProvider = known ? "" : entry.provider
            hostname = entry.hostname; username = entry.username; password = entry.password
            enabled = entry.enabled
        }
    }

    func input(wans: [WANConnectionRef]) -> DDNSInput? {
        guard let wan = wans.first(where: { $0.id == wanID }) else { return nil }
        return DDNSInput(wan: wan, provider: providerChoice == "Others" ? customProvider : providerChoice,
                         hostname: hostname, username: username, password: password, enabled: enabled)
    }

    var validationError: String? {
        let provider = providerChoice == "Others" ? customProvider : providerChoice
        guard [provider, hostname, username, password].allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else {
            return "服务商地址、域名、用户名和密码均须为 1–64 个字符。"
        }
        return nil
    }
}

private struct DDNSForm: View {
    @Binding var draft: DDNSDraft
    let wans: [WANConnectionRef]
    let editing: Bool
    let locked: Bool
    let saving: Bool
    let error: String?
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text(editing ? "编辑 DDNS" : "添加 DDNS")
                    .font(.system(size: 14, weight: .bold))
                field("WAN") {
                    Picker("WAN", selection: $draft.wanID) {
                        ForEach(wans) { wan in Text(wan.title).tag(wan.id) }
                    }
                    .labelsHidden()
                    .disabled(editing || locked)
                }
                field("服务商") {
                    Picker("服务商", selection: $draft.providerChoice) {
                        Text("DynDNS").tag("dyndns")
                        Text("TZO").tag("tzo")
                        Text("oray.com").tag("ORAY")
                        Text("No-IP.com").tag("No-IP.com")
                        Text("其他").tag("Others")
                    }
                    .labelsHidden().disabled(locked)
                }
                if draft.providerChoice == "Others" {
                    field("服务商地址") {
                        PanelTextField(text: $draft.customProvider, placeholder: "服务商地址").disabled(locked)
                    }
                }
                field("域名 / 主机名") {
                    PanelTextField(text: $draft.hostname, placeholder: "home.example.com").disabled(locked)
                }
                field("用户名") {
                    PanelTextField(text: $draft.username, placeholder: "DDNS 用户名").disabled(locked)
                }
                field("密码") {
                    PanelTextField(text: $draft.password, placeholder: "DDNS 密码", secure: true).disabled(locked)
                }
                Toggle("启用此条 DDNS", isOn: $draft.enabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(locked)
                if let error { StatusBanner(text: error, tone: .error) }
                HStack(spacing: 8) {
                    Button("取消", action: onCancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .keyboardShortcut(.cancelAction)
                        .disabled(saving)
                    Spacer(minLength: 0)
                    if saving { ProgressView().controlSize(.mini) }
                    Button(action: onSave) {
                        Text(saving ? "正在保存…" : "保存").frame(width: 92)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }
            }
            .padding(Theme.contentPadding)
        }
        .scrollIndicators(.automatic)
        .frame(width: Theme.compactWidth - 32)
        .frame(maxHeight: Theme.canvasHeight)
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
}

struct AdvancedSettingsDisconnectedState: View {
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.inkMuted)
            Text("设备已断开连接")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.contentPadding)
    }
}

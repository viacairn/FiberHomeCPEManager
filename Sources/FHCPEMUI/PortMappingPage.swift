import SwiftUI
import FHCPECore

public struct PortMappingPage: View {
    public let entries: [PortMappingEntry]
    public let wans: [WANConnectionRef]
    public let busy: Bool
    public let isLive: Bool
    public let status: String?
    public let statusIsError: Bool
    public let onBack: () -> Void
    public let onReload: () -> Void
    public let onAdd: (PortMappingInput) async throws -> Void
    public let onDelete: (PortMappingEntry) async throws -> Void
    public let onToggle: (PortMappingEntry, Bool) async throws -> Void

    public init(entries: [PortMappingEntry], wans: [WANConnectionRef], busy: Bool,
                isLive: Bool = true, status: String?, statusIsError: Bool,
                onBack: @escaping () -> Void, onReload: @escaping () -> Void,
                onAdd: @escaping (PortMappingInput) async throws -> Void,
                onDelete: @escaping (PortMappingEntry) async throws -> Void,
                onToggle: @escaping (PortMappingEntry, Bool) async throws -> Void) {
        self.entries = entries; self.wans = wans; self.busy = busy; self.isLive = isLive
        self.status = status; self.statusIsError = statusIsError
        self.onBack = onBack; self.onReload = onReload
        self.onAdd = onAdd; self.onDelete = onDelete; self.onToggle = onToggle
    }

    @State private var pageActive = true
    @State private var mutationToken: UUID?
    @State private var mutationTask: Task<Void, Never>?
    @State private var showingAdd = false
    @State private var deletingID: String?
    @State private var draft = PortMappingDraft()
    @State private var rowError: String?
    @State private var formError: String?

    private var working: Bool { busy || mutationToken != nil }
    private var canWrite: Bool { isLive && pageActive && !working }
    private var canOpenAction: Bool { canWrite && !showingAdd && deletingID == nil }
    private var availableWANs: [WANConnectionRef] {
        wans.filter { wan in
            entries.filter { $0.wan.id == wan.id }.count < PortMappingService.maxEntriesPerWAN
        }
    }
    private var canAdd: Bool { canOpenAction && !availableWANs.isEmpty }
    private var editorInput: PortMappingInput? { draft.input(wans: availableWANs) }
    private var validationError: String? {
        guard let input = editorInput else {
            return availableWANs.contains(where: { $0.id == draft.wanID })
                ? "请填写内网 IP 和完整的端口范围。" : "未读取到可用的 WAN 连接。"
        }
        if let error = input.validationError { return error }
        // The stock page checks every rule on the same WAN device, including disabled
        // rules and other protocols. The service repeats this check before writing.
        if entries.contains(where: {
            $0.wan.device == input.wan.device &&
            $0.externalPort <= input.externalEnd && input.externalPort <= $0.externalEnd
        }) {
            return "外部端口范围与现有规则重叠。"
        }
        return nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            SubpageBar(title: "端口映射", actionSymbol: canAdd ? "plus" : nil,
                       actionLabel: "添加端口映射", onAction: presentAdd, onBack: leavePage)
            if isLive {
                onlineContent
            } else {
                AdvancedSettingsDisconnectedState()
            }
        }
        .sheet(isPresented: editorPresentation, onDismiss: clearEditor) {
            if isLive {
                PortMappingForm(draft: $draft, wans: availableWANs, locked: working,
                                saving: mutationToken != nil, error: formError ?? validationError,
                                canSave: canWrite && editorInput != nil && validationError == nil,
                                onCancel: clearEditor, onSave: saveEditor)
            }
        }
        .confirmationDialog("删除端口映射？", isPresented: deletionPresentation,
                            titleVisibility: .visible, presenting: deletingID) { id in
            Button("删除", role: .destructive) { confirmDelete(id) }
                .disabled(!canWrite)
            Button("取消", role: .cancel) { deletingID = nil }
        } message: { _ in
            Text("将删除这条端口映射规则。")
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
            if showingAdd, !availableWANs.contains(where: { $0.id == draft.wanID }) { clearEditor() }
            if let deletingID, !entries.contains(where: { $0.id == deletingID }) { self.deletingID = nil }
        }
        .onChange(of: wans) { _, _ in
            if showingAdd, !availableWANs.contains(where: { $0.id == draft.wanID }) { clearEditor() }
            deletingID = nil
        }
        .onDisappear { invalidatePage() }
        .appReminder(rowError)
    }

    private var editorPresentation: Binding<Bool> {
        Binding(get: { isLive && showingAdd }, set: { if !$0 { clearEditor() } })
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
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.inkMuted)
            Text("没有端口映射规则")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            if !availableWANs.isEmpty {
                Text("点击右上角 + 添加一条规则")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func knowsWAN(_ entry: PortMappingEntry) -> Bool {
        wans.contains { $0.id == entry.wan.id }
    }

    private func row(_ entry: PortMappingEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.localIP)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                Text("\(entry.proto.title) · 内 \(entry.internalRange) · 外 \(entry.externalRange)")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                Text(entry.wan.title)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("端口映射启用", isOn: Binding(
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
            .accessibilityLabel("端口映射 \(entry.localIP) 启用")

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
            .help("删除端口映射")
            .accessibilityLabel("删除端口映射 \(entry.localIP)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    private func presentAdd() {
        guard canAdd else { return }
        draft = PortMappingDraft(wans: availableWANs)
        formError = nil
        showingAdd = true
    }

    private func saveEditor() {
        guard showingAdd, canWrite, let input = editorInput, validationError == nil else { return }
        mutate(fromEditor: true) { try await onAdd(input) }
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
        showingAdd = false
        draft = PortMappingDraft(); formError = nil
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

private struct PortMappingDraft {
    var wanID = ""
    var localIP = ""
    var internalPort = ""
    var internalEnd = ""
    var externalPort = ""
    var externalEnd = ""
    var proto: PortMappingProtocol = .tcp
    var enabled = false

    init(wans: [WANConnectionRef] = []) { wanID = wans.first?.id ?? "" }

    func input(wans: [WANConnectionRef]) -> PortMappingInput? {
        guard let wan = wans.first(where: { $0.id == wanID }),
              let firstInternal = Int(internalPort), let lastInternal = Int(internalEnd),
              let firstExternal = Int(externalPort), let lastExternal = Int(externalEnd) else { return nil }
        return PortMappingInput(wan: wan, localIP: localIP,
                                internalPort: firstInternal, internalEnd: lastInternal,
                                externalPort: firstExternal, externalEnd: lastExternal,
                                proto: proto, enabled: enabled)
    }
}

private struct PortMappingForm: View {
    @Binding var draft: PortMappingDraft
    let wans: [WANConnectionRef]
    let locked: Bool
    let saving: Bool
    let error: String?
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("添加端口映射")
                    .font(.system(size: 14, weight: .bold))
                field("WAN") {
                    Picker("WAN", selection: $draft.wanID) {
                        ForEach(wans) { wan in Text(wan.title).tag(wan.id) }
                    }
                    .labelsHidden().disabled(locked)
                }
                field("内网 IP") {
                    PanelTextField(text: $draft.localIP, placeholder: "192.168.8.120").disabled(locked)
                }
                HStack(spacing: 8) {
                    field("内部端口") {
                        PanelTextField(text: $draft.internalPort, placeholder: "8080").disabled(locked)
                    }
                    field("结束") {
                        PanelTextField(text: $draft.internalEnd, placeholder: "8080").disabled(locked)
                    }
                }
                HStack(spacing: 8) {
                    field("外部端口") {
                        PanelTextField(text: $draft.externalPort, placeholder: "18080").disabled(locked)
                    }
                    field("结束") {
                        PanelTextField(text: $draft.externalEnd, placeholder: "18080").disabled(locked)
                    }
                }
                field("协议") {
                    Picker("协议", selection: $draft.proto) {
                        ForEach(PortMappingProtocol.allCases, id: \.self) { item in Text(item.title).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(locked)
                }
                Toggle("启用此条规则", isOn: $draft.enabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(locked)
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
        .appReminder(error)
        .appNoticeOverlay(top: 36)
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

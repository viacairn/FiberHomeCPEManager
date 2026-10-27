import SwiftUI
import FHCPECore

public struct DDNSPage: View {
    @Bindable public var model: ShellModel
    @State private var deletingID: String?
    public init(model: ShellModel) { self.model = model }

    private var entries: [DDNSEntry] { model.ddnsEntries }
    private var wans: [WANConnectionRef] { model.wanConnections }
    private var busy: Bool { model.advancedBusy || model.advancedSaving }
    private var isLive: Bool { model.data.isLive }
    private var canWrite: Bool { isLive && !busy }
    private var canOpenAction: Bool { canWrite && !model.ddnsEditorPresented && deletingID == nil }
    private var availableWANs: [WANConnectionRef] {
        wans.filter { wan in entries.filter { $0.wan.id == wan.id }.count < 4 }
    }
    private var canAdd: Bool { canOpenAction && !availableWANs.isEmpty }
    private var editorWANs: [WANConnectionRef] { model.editingDDNS == nil ? availableWANs : wans }
    private var editorInput: DDNSInput? { model.ddnsDraft.input(wans: editorWANs) }
    private var validationError: String? {
        guard let input = editorInput else { return "请填写完整配置并选择可用的 WAN 连接。" }
        return model.ddnsDraft.validationError ?? input.validationError
    }

    public var body: some View {
        VStack(spacing: 0) {
            SubpageBar(title: "DDNS 设置", actionSymbol: canAdd ? "plus" : nil,
                       actionLabel: "添加 DDNS", onAction: { model.presentDDNSEditor(nil) },
                       onBack: model.closeDDNS)
            if isLive { onlineContent } else { AdvancedSettingsDisconnectedState() }
        }
        .sheet(isPresented: $model.ddnsEditorPresented, onDismiss: model.dismissDDNSEditor) {
            DDNSForm(draft: $model.ddnsDraft, wans: editorWANs, editing: model.editingDDNS != nil,
                     locked: busy, saving: model.advancedSaving,
                     error: isLive ? validationError : "连接暂时中断，恢复后可继续保存。",
                     canSave: canWrite && validationError == nil,
                     onCancel: model.dismissDDNSEditor, onSave: saveEditor)
        }
        .confirmationDialog("删除 DDNS？", isPresented: Binding(
            get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }),
            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let entry = entries.first(where: { $0.id == deletingID }) else { return }
                deletingID = nil
                model.performAdvancedMutation { try await model.deleteDDNS(entry) }
            }
            .disabled(!canWrite)
            Button("取消", role: .cancel) { deletingID = nil }
        }
    }

    private func saveEditor() {
        guard canWrite, validationError == nil, let input = editorInput else { return }
        let entry = model.editingDDNS
        model.performAdvancedMutation({
            try await model.saveDDNS(entry, input)
        }, onSuccess: model.dismissDDNSEditor)
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
            Button { model.presentDDNSEditor(entry) } label: {
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
                    model.performAdvancedMutation { try await model.setDDNSEnabled(entry, value) }
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
                if let error {
                    Text(error).font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

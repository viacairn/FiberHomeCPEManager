import SwiftUI
import FHCPECore

public struct PortMappingPage: View {
    @Bindable public var model: ShellModel
    @State private var deletingID: String?
    public init(model: ShellModel) { self.model = model }

    private var entries: [PortMappingEntry] { model.portMappings }
    private var wans: [WANConnectionRef] { model.wanConnections }
    private var busy: Bool { model.advancedBusy || model.advancedSaving }
    private var isLive: Bool { model.data.isLive }
    private var canWrite: Bool { isLive && !busy }
    private var canOpenAction: Bool { canWrite && !model.portMappingEditorPresented && deletingID == nil }
    private var availableWANs: [WANConnectionRef] {
        wans.filter { wan in entries.filter { $0.wan.id == wan.id }.count < PortMappingService.maxEntriesPerWAN }
    }
    private var canAdd: Bool { canOpenAction && !availableWANs.isEmpty }
    private var editorWANs: [WANConnectionRef] { model.editingPortMapping == nil ? availableWANs : wans }
    private var editorInput: PortMappingInput? { model.portMappingDraft.input(wans: editorWANs) }
    private var validationError: String? {
        guard let input = editorInput else { return "请填写完整配置并选择可用的 WAN 连接。" }
        return input.validationError
    }

    public var body: some View {
        VStack(spacing: 0) {
            SubpageBar(title: "端口映射", actionSymbol: canAdd ? "plus" : nil,
                       actionLabel: "添加端口映射", onAction: { model.presentPortMappingEditor(nil) },
                       onBack: model.closePortMapping)
            if isLive { onlineContent } else { AdvancedSettingsDisconnectedState() }
        }
        .sheet(isPresented: $model.portMappingEditorPresented, onDismiss: model.dismissPortMappingEditor) {
            PortMappingForm(draft: $model.portMappingDraft, wans: editorWANs, devices: model.devices,
                            editing: model.editingPortMapping != nil, locked: busy, saving: model.advancedSaving,
                     error: isLive ? validationError : "连接暂时中断，恢复后可继续保存。",
                     canSave: canWrite && validationError == nil,
                     onCancel: model.dismissPortMappingEditor, onSave: saveEditor)
        }
        .confirmationDialog("删除端口映射？", isPresented: Binding(
            get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }),
            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let entry = entries.first(where: { $0.id == deletingID }) else { return }
                deletingID = nil
                model.performAdvancedMutation { try await model.deletePortMapping(entry) }
            }
            .disabled(!canWrite)
            Button("取消", role: .cancel) { deletingID = nil }
        }
    }

    private func saveEditor() {
        guard canWrite, validationError == nil, let input = editorInput else { return }
        let entry = model.editingPortMapping
        model.performAdvancedMutation({
            if let entry { try await model.updatePortMapping(entry, input) }
            else { try await model.addPortMapping(input) }
        }, onSuccess: model.dismissPortMappingEditor)
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
            Button { model.presentPortMappingEditor(entry) } label: {
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
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpenAction || !knowsWAN(entry))
            .accessibilityLabel("编辑端口映射 \(entry.localIP)")

            Toggle("端口映射启用", isOn: Binding(
                get: { entry.enabled },
                set: { value in
                    guard canOpenAction, knowsWAN(entry) else { return }
                    model.performAdvancedMutation { try await model.setPortMappingEnabled(entry, value) }
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

}

private struct PortMappingForm: View {
    @Binding var draft: PortMappingDraft
    let wans: [WANConnectionRef]
    let devices: [ConnectedDevice]
    let editing: Bool
    let locked: Bool
    let saving: Bool
    let error: String?
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    private var onlineDevices: [ConnectedDevice] {
        devices.filter { !$0.ip.isEmpty && $0.ip != "—" }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text(editing ? "编辑端口映射" : "添加端口映射")
                    .font(.system(size: 14, weight: .bold))
                field("WAN") {
                    Picker("WAN", selection: $draft.wanID) {
                        ForEach(wans) { wan in Text(wan.title).tag(wan.id) }
                    }
                    .labelsHidden().disabled(locked || editing)
                }
                field("内网 IP") {
                    HStack(spacing: 6) {
                        PanelTextField(text: $draft.localIP, placeholder: "192.168.8.120").disabled(locked)
                        Menu {
                            ForEach(onlineDevices) { device in
                                Button("\(device.name) · \(device.ip)") { draft.localIP = device.ip }
                            }
                        } label: { Image(systemName: "desktopcomputer") }
                        .menuStyle(.borderlessButton).frame(width: 24)
                        .disabled(locked || onlineDevices.isEmpty)
                        .help("从在线设备选择 IP")
                    }
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
                    field("外部起始端口") {
                        PanelTextField(text: Binding(get: { draft.externalPort }, set: { draft.setExternalPort($0) }), placeholder: "18080").disabled(locked)
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

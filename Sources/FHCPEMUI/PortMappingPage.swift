import SwiftUI
import FHCPECore

public struct PortMappingPage: View {
    public let entries: [PortMappingEntry]
    public let wans: [WANConnectionRef]
    public let busy: Bool
    public let status: String?
    public let statusIsError: Bool
    public let onBack: () -> Void
    public let onReload: () -> Void
    public let onAdd: (PortMappingInput) async throws -> Void
    public let onDelete: (PortMappingEntry) async throws -> Void
    public let onToggle: (PortMappingEntry, Bool) async throws -> Void

    public init(entries: [PortMappingEntry], wans: [WANConnectionRef], busy: Bool,
                status: String?, statusIsError: Bool,
                onBack: @escaping () -> Void, onReload: @escaping () -> Void,
                onAdd: @escaping (PortMappingInput) async throws -> Void,
                onDelete: @escaping (PortMappingEntry) async throws -> Void,
                onToggle: @escaping (PortMappingEntry, Bool) async throws -> Void) {
        self.entries = entries; self.wans = wans; self.busy = busy
        self.status = status; self.statusIsError = statusIsError
        self.onBack = onBack; self.onReload = onReload
        self.onAdd = onAdd; self.onDelete = onDelete; self.onToggle = onToggle
    }

    @State private var showingAdd = false
    @State private var rowError: String?

    public var body: some View {
        VStack(spacing: 0) {
            SubpageBar(title: "端口映射", actionSymbol: "plus", actionLabel: "添加端口映射",
                       onAction: { showingAdd = true }, onBack: onBack)
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
        .sheet(isPresented: $showingAdd) {
            PortMappingForm(wans: wans, onAdd: onAdd)
        }
        .onChange(of: entries) { _, _ in rowError = nil }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.inkMuted)
            Text("没有端口映射规则")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text("点击右上角 + 添加一条规则")
                .font(.system(size: 10))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
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

            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { value in mutate { try await onToggle(entry, value) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(busy)
            .accessibilityLabel("端口映射 \(entry.localIP) 启用")

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
            .help("删除端口映射")
            .accessibilityLabel("删除端口映射 \(entry.localIP)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    private func mutate(_ action: @escaping () async throws -> Void) {
        rowError = nil
        Task { @MainActor in
            do { try await action(); onReload() }
            catch { rowError = error.localizedDescription }
        }
    }
}

private struct PortMappingForm: View {
    let wans: [WANConnectionRef]
    let onAdd: (PortMappingInput) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var wanID: String
    @State private var localIP = ""
    @State private var internalPort = ""
    @State private var internalEnd = ""
    @State private var externalPort = ""
    @State private var externalEnd = ""
    @State private var proto: PortMappingProtocol = .tcp
    @State private var enabled = true
    @State private var saving = false
    @State private var saveError: String?

    init(wans: [WANConnectionRef], onAdd: @escaping (PortMappingInput) async throws -> Void) {
        self.wans = wans; self.onAdd = onAdd
        self._wanID = State(initialValue: wans.first?.id ?? "")
    }

    private var selectedWAN: WANConnectionRef? { wans.first { $0.id == wanID } ?? wans.first }

    private var input: PortMappingInput? {
        guard let wan = selectedWAN,
              let internalPort = Int(internalPort), let internalEnd = Int(internalEnd),
              let externalPort = Int(externalPort), let externalEnd = Int(externalEnd) else { return nil }
        return PortMappingInput(wan: wan, localIP: localIP,
                                internalPort: internalPort, internalEnd: internalEnd,
                                externalPort: externalPort, externalEnd: externalEnd,
                                proto: proto, enabled: enabled)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加端口映射")
                .font(.system(size: 14, weight: .bold))
            if wans.count > 1 {
                field("WAN") {
                    Picker("WAN", selection: $wanID) {
                        ForEach(wans) { wan in Text(wan.title).tag(wan.id) }
                    }
                    .labelsHidden().disabled(saving)
                }
            }
            field("内网 IP") {
                PanelTextField(text: $localIP, placeholder: "192.168.8.120").disabled(saving)
            }
            HStack(spacing: 8) {
                field("内部端口") {
                    PanelTextField(text: $internalPort, placeholder: "8080").disabled(saving)
                }
                field("结束") {
                    PanelTextField(text: $internalEnd, placeholder: "8080").disabled(saving)
                }
            }
            HStack(spacing: 8) {
                field("外部端口") {
                    PanelTextField(text: $externalPort, placeholder: "18080").disabled(saving)
                }
                field("结束") {
                    PanelTextField(text: $externalEnd, placeholder: "18080").disabled(saving)
                }
            }
            field("协议") {
                Picker("协议", selection: $proto) {
                    ForEach(PortMappingProtocol.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(saving)
            }
            Toggle("启用此条规则", isOn: $enabled)
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
            do { try await onAdd(input); dismiss() }
            catch { saveError = error.localizedDescription }
        }
    }
}

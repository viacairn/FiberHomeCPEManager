import SwiftUI
import FHCPECore

struct DDNSDraft {
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

struct PortMappingDraft {
    var wanID = ""
    var localIP = ""
    var internalPort = ""
    var internalEnd = ""
    var externalPort = ""
    var externalEnd = ""
    var proto: PortMappingProtocol = .tcp
    var enabled = false

    init(wans: [WANConnectionRef] = []) { wanID = wans.first?.id ?? "" }

    init(entry: PortMappingEntry, wans: [WANConnectionRef]) {
        wanID = entry.wan.id; localIP = entry.localIP
        internalPort = String(entry.internalPort); internalEnd = String(entry.internalEnd)
        externalPort = String(entry.externalPort); externalEnd = String(entry.externalEnd)
        proto = entry.proto; enabled = entry.enabled
    }

    mutating func setExternalPort(_ value: String) {
        let previous = externalPort
        if externalEnd.isEmpty || externalEnd == previous { externalEnd = value }
        if internalPort.isEmpty || internalPort == previous { internalPort = value }
        if internalEnd.isEmpty || internalEnd == previous { internalEnd = value }
        externalPort = value
    }

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


@MainActor extension ShellModel {
    func presentDDNSEditor(_ entry: DDNSEntry?) {
        guard data.isLive, !advancedBusy, !advancedSaving else { return }
        editingDDNS = entry
        ddnsDraft = DDNSDraft(entry: entry, wans: wanConnections)
        ddnsEditorPresented = true
    }

    func dismissDDNSEditor() {
        ddnsEditorPresented = false; editingDDNS = nil; ddnsDraft = DDNSDraft()
    }

    func presentPortMappingEditor(_ entry: PortMappingEntry?) {
        guard data.isLive, !advancedBusy, !advancedSaving else { return }
        editingPortMapping = entry
        portMappingDraft = entry.map { PortMappingDraft(entry: $0, wans: wanConnections) }
            ?? PortMappingDraft(wans: wanConnections)
        portMappingEditorPresented = true
    }

    func dismissPortMappingEditor() {
        portMappingEditorPresented = false; editingPortMapping = nil; portMappingDraft = PortMappingDraft()
    }

    /// The shell owns writes and editor lifetime, including while a poll is stale.
    func performAdvancedMutation(_ action: @escaping @MainActor () async throws -> Void,
                                 onSuccess: @escaping @MainActor () -> Void = {}) {
        guard data.isLive, !advancedBusy, !advancedSaving else { return }
        advancedSaving = true
        advancedTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.advancedSaving = false; self.advancedTask = nil } }
            do {
                try await action()
                guard !Task.isCancelled else { return }
                onSuccess()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      error as? CPEError != .authentication else { return }
                self.notices.show(error.localizedDescription, tone: .error)
            }
        }
    }
}

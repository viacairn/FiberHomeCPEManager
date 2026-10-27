import Testing
import Foundation
import AppKit
import SwiftUI
@testable import FHCPECore
@testable import FHCPEMUI

@MainActor @Suite(.serialized) struct ShellSessionTests {
    @Test(arguments: [ShellView.Route.ddns, .portMapping])
    func staleTransitionKeepsPresentedEditor(_ route: ShellView.Route) throws {
        _ = NSApplication.shared
        let model = populatedModel()
        model.route = route
        model.wanConnections = [WANConnectionRef(device: 1, link: .ipoe, name: "INTERNET_R", enabled: true)]
        let controller = PopoverHostingController(rootView: ShellView(model: model),
                                                  designSize: NSSize(width: 350, height: Theme.compactHeight))
        let window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.contentViewController = controller
        window.orderFrontRegardless()
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if route == .ddns {
            model.presentDDNSEditor(nil)
            model.ddnsDraft.hostname = "unsaved.example.com"
        } else {
            model.presentPortMappingEditor(nil)
            model.portMappingDraft.localIP = "192.168.8.123"
        }
        let deadline = Date().addingTimeInterval(2)
        while window.sheets.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try #require(window.sheets.count == 1)
        model.data = PageData(snapshot: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(window.sheets.count == 1)
        if route == .ddns {
            #expect(model.ddnsEditorPresented)
            #expect(model.ddnsDraft.hostname == "unsaved.example.com")
        } else {
            #expect(model.portMappingEditorPresented)
            #expect(model.portMappingDraft.localIP == "192.168.8.123")
        }
    }

    @Test func disconnectErasesVolatilePagesAndDrafts() {
        let model = populatedModel()
        model.resetSession()
        expectCleared(model)
    }

    @Test func staleReadingPreservesDraftsAndEditors() {
        let model = populatedModel()
        model.ddnsEditorPresented = true
        model.portMappingEditorPresented = true
        model.ddnsDraft.hostname = "unsaved.example.com"
        model.portMappingDraft.localIP = "192.168.8.123"
        model.data.stale = true
        #expect(model.draftNumber == "10010")
        #expect(model.draftBody == "draft")
        #expect(model.replyBody == "reply")
        #expect(model.ddnsEditorPresented && model.portMappingEditorPresented)
        #expect(model.ddnsDraft.hostname == "unsaved.example.com")
        #expect(model.portMappingDraft.localIP == "192.168.8.123")
    }

    @Test func portAutofillPreservesManuallyChangedValues() {
        var draft = PortMappingDraft()
        draft.setExternalPort("8080")
        #expect(draft.externalEnd == "8080" && draft.internalPort == "8080" && draft.internalEnd == "8080")
        draft.internalPort = "80"
        draft.externalEnd = "8090"
        draft.setExternalPort("9000")
        #expect(draft.externalEnd == "8090")
        #expect(draft.internalPort == "80")
        #expect(draft.internalEnd == "9000")
    }

    @Test func successfulSaveDismissesEditorThroughModel() async {
        let model = populatedModel()
        model.ddnsEditorPresented = true
        model.ddnsDraft.hostname = "unsaved.example.com"
        model.performAdvancedMutation({}, onSuccess: model.dismissDDNSEditor)
        #expect(model.advancedSaving)
        await model.advancedTask?.value
        #expect(!model.advancedSaving)
        #expect(!model.ddnsEditorPresented)
        #expect(model.ddnsDraft.hostname.isEmpty)
    }

    @Test func failedSavePreservesEditorAndDraft() async {
        let model = populatedModel()
        model.portMappingEditorPresented = true
        model.portMappingDraft.localIP = "192.168.8.123"
        model.performAdvancedMutation({ throw CPEError.rejected }, onSuccess: model.dismissPortMappingEditor)
        await model.advancedTask?.value
        #expect(!model.advancedSaving)
        #expect(model.portMappingEditorPresented)
        #expect(model.portMappingDraft.localIP == "192.168.8.123")
        #expect(model.notices.notices.last?.tone == .error)
    }

    @Test func authenticationRenewalKeepsEditorQuiet() async {
        let model = populatedModel()
        model.ddnsEditorPresented = true
        model.ddnsDraft.hostname = "unsaved.example.com"
        model.performAdvancedMutation({ throw CPEError.authentication }, onSuccess: model.dismissDDNSEditor)
        await model.advancedTask?.value
        #expect(model.notices.notices.isEmpty)
        #expect(model.ddnsEditorPresented)
        #expect(model.ddnsDraft.hostname == "unsaved.example.com")
    }

    private func populatedModel() -> ShellModel {
        var snapshot = DeviceSnapshot(); snapshot.model = "LG6851F"
        let model = ShellModel(route: .main, data: PageData(snapshot: snapshot, connected: true))
        model.devices = [ConnectedDevice(id: "one", name: "Phone", ip: "192.168.8.101", access: .wifi5G)]
        model.cells = [CellRecord(tech: .nr, band: "n78", pci: "101", state: .serving)]
        model.settings = DeviceSettings()
        model.threads = [SMSThread(phone: "10010", messages: [SMSMessage(id: "1", sender: "10010", body: "private body", date: "2026/10/18 10:00:00", isRead: false)])]
        model.selectedThreadID = "10010"; model.smsRoute = .thread
        model.draftNumber = "10010"; model.draftBody = "draft"; model.replyBody = "reply"
        model.smsLastSync = .now
        model.smsBusy = true; model.settingsBusy = true; model.lockBusy = true
        return model
    }

    private func expectCleared(_ model: ShellModel) {
        #expect(model.data.snapshot == nil)
        #expect(model.devices.isEmpty)
        #expect(model.cells.isEmpty)
        #expect(model.settings == nil)
        #expect(model.threads.isEmpty)
        #expect(model.selectedThreadID == nil)
        #expect(model.smsRoute == .threads)
        #expect(model.smsLastSync == nil)
        #expect(model.draftNumber.isEmpty && model.draftBody.isEmpty && model.replyBody.isEmpty)
        #expect(!model.smsBusy && !model.settingsBusy && !model.lockBusy)
    }
}

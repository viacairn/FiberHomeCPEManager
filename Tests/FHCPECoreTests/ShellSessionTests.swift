import Testing
import Foundation
@testable import FHCPECore
@testable import FHCPEMUI

@MainActor struct ShellSessionTests {
    @Test func disconnectErasesVolatilePagesAndDrafts() {
        let model = populatedModel()
        model.data.connected = false
        expectCleared(model)
    }

    @Test func staleReadingErasesVolatilePagesAndDrafts() {
        let model = populatedModel()
        model.data.stale = true
        expectCleared(model)
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

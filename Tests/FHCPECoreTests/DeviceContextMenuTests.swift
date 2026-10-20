import AppKit
import Testing
import FHCPECore
@testable import FHCPEMUI

@MainActor
struct DeviceContextMenuTests {
    private func device(_ id: String) -> ConnectedDevice {
        ConnectedDevice(id: id, name: id, ip: "192.0.2.10", access: .wired,
                        mac: "02:00:00:00:00:10")
    }

    @Test func openMenuKeepsItsSelectedDeviceAcrossPollingUpdates() throws {
        _ = NSApplication.shared
        let view = DeviceMenuView()
        var selected: [String] = []
        view.configure(device: device("original"), glyph: nil, canReserveIP: true,
                       onReserve: { selected.append($0.id) }, onGlyph: { _, _ in })
        let menu = try #require(view.makeMenuSnapshot())
        for index in 0..<30 {
            view.configure(device: device("update-\(index)"), glyph: nil, canReserveIP: true,
                           onReserve: { selected.append($0.id) }, onGlyph: { _, _ in })
        }
        menu.performActionForItem(at: 0)
        #expect(selected == ["original"])
        let next = try #require(view.makeMenuSnapshot())
        next.performActionForItem(at: 0)
        #expect(selected == ["original", "update-29"])
    }

    @Test func iconSubmenuRetainsItsTargetsAfterTheRowIsReleased() throws {
        _ = NSApplication.shared
        var assigned: DeviceGlyph?
        var selectedID: String?
        var view: DeviceMenuView? = DeviceMenuView()
        view?.configure(device: device("original"), glyph: nil, canReserveIP: true,
                        onReserve: { _ in }, onGlyph: { selected, glyph in
                            selectedID = selected.id; assigned = glyph
                        })
        let menu = try #require(view?.makeMenuSnapshot())
        let icons = try #require(menu.items.first { $0.title == "设置图标" }?.submenu)
        view = nil
        icons.performActionForItem(at: 0)
        #expect(selectedID == "original")
        #expect(assigned == DeviceGlyph.allCases.first)
    }
}

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

    @Test func copyActionsUseTheDeviceCapturedWhenTheMenuOpened() throws {
        _ = NSApplication.shared
        let view = DeviceMenuView()
        var copied: [String] = []
        view.configure(device: device("original"), glyph: nil, canReserveIP: true,
                       onReserve: { _ in }, onGlyph: { _, _ in }, onCopy: { copied.append($0) })
        let menu = try #require(view.makeMenuSnapshot())
        var updated = device("original")
        updated.ip = "192.0.2.11"
        updated.mac = "02:00:00:00:00:11"
        view.configure(device: updated, glyph: nil, canReserveIP: true,
                       onReserve: { _ in }, onGlyph: { _, _ in }, onCopy: { copied.append($0) })
        let ipIndex = try #require(menu.items.firstIndex { $0.title == "复制 IP 地址" })
        let macIndex = try #require(menu.items.firstIndex { $0.title == "复制 MAC 地址" })
        menu.performActionForItem(at: ipIndex)
        menu.performActionForItem(at: macIndex)
        #expect(copied == ["192.0.2.10", "02:00:00:00:00:10"])
    }

    @Test(arguments: ["192.0.2.11", "", "—"])
    func missingAddressesDisableCopyActions(_ ip: String) throws {
        _ = NSApplication.shared
        let view = DeviceMenuView()
        let client = ConnectedDevice(id: "unknown", name: "Unknown", ip: ip, access: .wired)
        view.configure(device: client, glyph: nil, canReserveIP: false,
                       onReserve: { _ in }, onGlyph: { _, _ in })
        let menu = try #require(view.makeMenuSnapshot())
        let item = try #require(menu.items.first { $0.title == "复制 MAC 地址" })
        #expect(!item.isEnabled)
        let copyIP = try #require(menu.items.first { $0.title == "复制 IP 地址" })
        #expect(copyIP.isEnabled == (!ip.isEmpty && ip != "—"))
    }

    @Test func removingAReservationUsesTheDeviceCapturedByTheMenu() throws {
        _ = NSApplication.shared
        let view = DeviceMenuView()
        var removed: [String] = []
        view.configure(device: device("reserved"), glyph: nil, canReserveIP: true,
                       onReserve: { _ in }, onGlyph: { _, _ in }, isReserved: true,
                       canRemoveReservation: true, onRemove: { removed.append($0.id) })
        let menu = try #require(view.makeMenuSnapshot())
        view.configure(device: device("updated"), glyph: nil, canReserveIP: true,
                       onReserve: { _ in }, onGlyph: { _, _ in })
        let index = try #require(menu.items.firstIndex { $0.title == "解除固定 IP 绑定" })
        menu.performActionForItem(at: index)
        #expect(removed == ["reserved"])
        #expect(view.makeMenuSnapshot()?.items.contains { $0.title == "解除固定 IP 绑定" } == false)
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

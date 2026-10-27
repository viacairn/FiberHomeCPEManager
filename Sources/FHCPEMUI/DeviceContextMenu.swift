import AppKit
import SwiftUI
import FHCPECore

/// SwiftUI owns the selected device; AppKit owns a fixed menu while it is tracking.
/// Polling may update the row without destroying its open icon submenu.
struct DeviceContextMenu: NSViewRepresentable {
    let device: ConnectedDevice
    let glyph: DeviceGlyph?
    let canReserveIP: Bool
    let onReserve: (ConnectedDevice) -> Void
    let onGlyph: (ConnectedDevice, DeviceGlyph?) -> Void
    var isReserved = false
    var canRemoveReservation = false
    var onRemove: (ConnectedDevice) -> Void = { _ in }

    func makeNSView(context: Context) -> DeviceMenuView { DeviceMenuView() }

    func updateNSView(_ view: DeviceMenuView, context: Context) {
        view.configure(device: device, glyph: glyph, canReserveIP: canReserveIP,
                       onReserve: onReserve, onGlyph: onGlyph, isReserved: isReserved,
                       canRemoveReservation: canRemoveReservation, onRemove: onRemove)
    }

    static func dismantleNSView(_ view: DeviceMenuView, coordinator: ()) {
        view.cancelTracking()
    }
}

@MainActor
final class DeviceMenuView: NSView {
    private var device: ConnectedDevice?
    private var glyph: DeviceGlyph?
    private var canReserveIP = false
    private var isReserved = false
    private var canRemoveReservation = false
    private var onRemove: ((ConnectedDevice) -> Void)?
    private var onReserve: ((ConnectedDevice) -> Void)?
    private var onGlyph: ((ConnectedDevice, DeviceGlyph?) -> Void)?
    private var onCopy: ((String) -> Void)?
    private var activeMenu: NSMenu?

    func configure(device: ConnectedDevice, glyph: DeviceGlyph?, canReserveIP: Bool,
                   onReserve: @escaping (ConnectedDevice) -> Void,
                   onGlyph: @escaping (ConnectedDevice, DeviceGlyph?) -> Void,
                   isReserved: Bool = false, canRemoveReservation: Bool = false,
                   onRemove: @escaping (ConnectedDevice) -> Void = { _ in },
                   onCopy: @escaping (String) -> Void = { value in
                       NSPasteboard.general.clearContents()
                       NSPasteboard.general.setString(value, forType: .string)
                   }) {
        if self.device?.id != device.id || self.device?.mac != device.mac { cancelTracking() }
        self.device = device; self.glyph = glyph; self.canReserveIP = canReserveIP
        self.onReserve = onReserve; self.onGlyph = onGlyph; self.onCopy = onCopy
        self.isReserved = isReserved; self.canRemoveReservation = canRemoveReservation; self.onRemove = onRemove
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(device.name)，\(device.ip)，\(device.access.title)\(isReserved ? "，已绑定固定 IP" : "")")
        setAccessibilityHelp("右键复制地址、管理固定 IP 或设备图标")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown ||
                (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) { presentMenu(event: event) }
    override func mouseDown(with event: NSEvent) { presentMenu(event: event) }

    override func accessibilityPerformShowMenu() -> Bool {
        guard device != nil else { return false }
        // Return to the AX caller before entering AppKit's nested menu-tracking loop.
        Task { @MainActor [weak self] in self?.presentMenu(event: nil) }
        return true
    }

    func cancelTracking() { activeMenu?.cancelTracking(); activeMenu = nil }

    private func presentMenu(event: NSEvent?) {
        guard let menu = makeMenuSnapshot() else { return }
        activeMenu = menu
        defer { activeMenu = nil }
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 8, y: bounds.midY), in: self)
        }
    }

    func makeMenuSnapshot() -> NSMenu? {
        guard let device, let onReserve, let onGlyph, let onCopy else { return nil }
        let menu = DeviceActionMenu(title: "设备配置")
        menu.autoenablesItems = false
        menu.append(isReserved ? "修改固定 IP…" : "设置固定 IP…", symbol: "pin", enabled: canReserveIP) { onReserve(device) }
        if isReserved, let onRemove {
            menu.append("解除固定 IP 绑定", symbol: "pin.slash", enabled: canRemoveReservation) { onRemove(device) }
        }
        menu.addItem(.separator())
        menu.append("复制 IP 地址", symbol: "doc.on.doc", enabled: !device.ip.isEmpty && device.ip != "—") {
            onCopy(device.ip)
        }
        let mac = device.mac?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        menu.append("复制 MAC 地址", symbol: "doc.on.doc", enabled: !mac.isEmpty) {
            onCopy(mac)
        }
        menu.addItem(.separator())
        let icons = DeviceActionMenu(title: "设置图标")
        icons.autoenablesItems = false
        for candidate in DeviceGlyph.allCases {
            let item = icons.append(candidate.title, symbol: candidate.symbol) { onGlyph(device, candidate) }
            item.state = glyph == candidate ? .on : .off
        }
        let parent = NSMenuItem(title: "设置图标", action: nil, keyEquivalent: "")
        parent.submenu = icons
        menu.addItem(parent)
        menu.append("恢复自动识别") { onGlyph(device, nil) }
        return menu
    }
}

@MainActor
private final class DeviceActionMenu: NSMenu {
    private var handlers: [DeviceMenuAction] = []

    @discardableResult
    func append(_ title: String, symbol: String? = nil, enabled: Bool = true,
                action: @escaping () -> Void) -> NSMenuItem {
        let handler = DeviceMenuAction(action)
        handlers.append(handler) // NSMenuItem.target is weak: retain it for the whole menu.
        let item = NSMenuItem(title: title, action: #selector(DeviceMenuAction.invokeMenuAction), keyEquivalent: "")
        item.target = handler; item.isEnabled = enabled
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        addItem(item)
        return item
    }
}

@MainActor
private final class DeviceMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invokeMenuAction() { action() }
}

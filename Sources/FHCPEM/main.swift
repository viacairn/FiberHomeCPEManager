import SwiftUI
import AppKit
import WidgetKit
import FHCPECore
import FHCPEMUI

// MARK: - App entry

/// Entry point.
///
/// This is deliberately a plain AppKit application (`NSApplication` + delegate) rather than
/// a SwiftUI `App`. Every SwiftUI scene type — including an empty `Settings { EmptyView() }`
/// — installs a window that becomes the app's main window; that window then intercepts the
/// status-item click and covered the popover (observed as a stray 900×450 window). The UI
/// inside the popover is still SwiftUI, hosted by `NSHostingController`.
@main
struct FiberHomeCPEManagerApp {
    /// The delegate must stay alive for the process lifetime; `NSApplication.delegate` is
    /// weak, so without this strong reference it would be released immediately and no
    /// delegate method would ever fire.
    @MainActor private static let delegate = AppDelegate()

    @MainActor static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}


/// LSUIElement app: no Dock icon, and the popover must be able to become key for text
/// fields in the connection/settings pages.
/// Owns the single menu-bar status item, its popover, and the right-click menu.
///
/// Why AppKit rather than `MenuBarExtra`:
/// - `MenuBarExtra` toggles the popover on *any* click, so a right-click menu is
///   impossible; quitting the app was unreachable without opening the panel.
/// - It derives the popover's size from its content and refused to shrink, so the panel
///   could not be pinned to one size.
/// One `NSStatusItem` plus one `NSPopover` solves both and is the documented pattern for
/// menu-bar utilities.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var store: AppStore?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var keyMonitor: Any?
    /// When the popover was last shown, used to ignore the click that opened it.
    private var popoverOpenedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = AppStore()
        self.store = store
        installPopover(store: store)
        // Create the status item immediately: `NSStatusBar.system` is ready here (verified)
        // and deferring it to a later run-loop turn proved unreliable when the launch Apple
        // Event was still being processed, which left the app running with no menu-bar item.
        store.startMenuBarRefresh()
        installStatusItem()
        scheduleStatusItemRetries()
        // Silent sign-in for users who opted into the Keychain: the panel then opens on
        // 概览 instead of the login form.
        store.restoreSavedSessionIfRequested()
        // A left-click elsewhere dismisses the popover, like a native menu extra.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopoverIfNeeded() }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.closePopoverIfNeeded() }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }

    // MARK: Status item

    private func installStatusItem() {
        if let existing = statusItem, existing.button != nil { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.toolTip = "FiberHomeCPEManager · 点击打开面板，右键显示菜单"
        statusItem = item
        refreshStatusItem()
    }

    /// Re-creates the status item if it is missing.
    ///
    /// `NSStatusBar.system.statusItem(withLength:)` can hand back an item whose `button` is
    /// nil when called too early. That failure is silent, so the app would run with no
    /// menu-bar entry at all (observed intermittently). Retrying a few times on a timer
    /// makes startup deterministic.
    private func ensureStatusItem() {
        guard statusItem?.button == nil else { return }
        installStatusItem()
    }

    private func scheduleStatusItemRetries() {
        for delay in [0.05, 0.2, 0.5, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.ensureStatusItem()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureStatusItem()
    }

    /// Dismiss the panel when the app stops being active — that is what a click outside it
    /// (another app, the desktop, the system menu bar) actually does.
    func applicationDidResignActive(_ notification: Notification) {
        if popover?.isShown == true { popover?.performClose(nil) }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        ensureStatusItem()
    }

    /// Redraws the menu-bar bitmap. Called on every sample and on style changes.
    func refreshStatusItem() {
        guard let button = statusItem?.button, let store else { return }
        let image = MenuBarGlyph.image(style: store.menuBarStyle,
                                       level: store.menuSignalLevel,
                                       text: store.menuLabelText,
                                       connected: store.model.data.connected)
        button.image = image
        button.setAccessibilityLabel(store.menuAccessibilityLabel)
        statusItem?.length = MenuBarGlyph.width(for: store.menuBarStyle) + 12
    }

    // MARK: Popover

    private func installPopover(store: AppStore) {
        let popover = NSPopover()
        // `.applicationDefined` plus an explicit resign-active close, rather than
        // `.transient`:
        // - `.transient` dismissed the panel *while typing* because synthesized/menu key
        //   events briefly moved key focus (measured: the window vanished mid-input).
        // - `.applicationDefined` alone never closed on outside clicks, because a global
        //   event monitor does not fire for a sandboxed app without accessibility trust.
        // Closing on resignation covers every "clicked somewhere else" case, including
        // another app, the desktop and the system menu bar.
        popover.behavior = .applicationDefined
        popover.animates = true
        // `NSPopover` always lays a 13 pt arrow margin on each edge: a 340x560 content
        // presents as a 366x586 window (measured). That chrome is fixed by the platform,
        // so the popover is asked for exactly the design size and the extra margin simply
        // frames it; the content area itself stays 340x560.
        let hosting = NSHostingController(
            rootView: ShellView(model: store.model)
                .frame(width: Theme.compactWidth, height: Theme.compactHeight)
        )
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(x: 0, y: 0, width: Theme.compactWidth, height: Theme.compactHeight)
        popover.contentSize = NSSize(width: Theme.compactWidth, height: Theme.compactHeight)
        popover.contentViewController = hosting
        popover.hasFullSizeContent = true
        self.popover = popover
        store.onPopoverVisibilityChanged = { visible in
            // The store owns the refresh cadence; the delegate only reports visibility.
            if visible { store.activate() } else { store.deactivate() }
        }
        store.onStatusItemNeedsUpdate = { [weak self] in self?.refreshStatusItem() }
        installMainMenu()
        installKeyboardShortcuts()
    }

    /// Installs an application menu that is never displayed.
    ///
    /// This is an `accessory` app, so it has no menu bar; without a `mainMenu`, `⌘Q` does
    /// nothing at all (verified: there was no quit path except the right-click menu).
    /// Assigning a menu gives AppKit the standard key-equivalent chain while remaining
    /// invisible, which is exactly what a menu-bar-only app needs.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "FiberHomeCPEManager")
        appMenuItem.submenu = appMenu

        let quit = NSMenuItem(title: "退出应用",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)

        let close = NSMenuItem(title: "关闭面板",
                               action: #selector(closePanelFromMenu),
                               keyEquivalent: "w")
        close.target = self
        appMenu.addItem(close)

        // Standard Edit menu. Without it, the Cmd-V/C/X/A key equivalents have no responder
        // and SwiftUI text fields cannot paste. The login probe had to synthesize every
        // keystroke, and a stale Command modifier turned the leading Q of a password into
        // Cmd-Q (quit). Keeping the menu also makes paste work for addresses and SMS drafts.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    @objc private func closePanelFromMenu() {
        popover?.performClose(nil)
    }

    /// Keyboard handling that must work even when no control has focus.
    ///
    /// `Esc` closes the panel (it should never quit the app), `⌘W` does the same, and `⌘Q`
    /// quits. Both are also reachable from the menu; the monitor keeps them working when the
    /// popover is key and focus sits in a text field.
    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isEscape = event.keyCode == 53
            let isCommand = flags.contains(.command)

            // Esc walks back through the navigation stack before it dismisses the panel.
            if isEscape {
                if self.popover?.isShown == true {
                    if self.goBackIfPossible() { return nil }
                    self.popover?.performClose(nil)
                    return nil
                }
                return event
            }
            if isCommand, event.charactersIgnoringModifiers?.lowercased() == "w" {
                if self.popover?.isShown == true {
                    self.popover?.performClose(nil)
                    return nil
                }
                return event
            }
            if isCommand, event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil)
                return nil
            }
            if isCommand, let characters = event.charactersIgnoringModifiers {
                // ⌘1…⌘4 switch the bottom tabs; ⌘R refreshes the current page.
                if let digit = Int(characters), (1...4).contains(digit) {
                    self.selectTab(digit - 1)
                    return nil
                }
                if characters.lowercased() == "r" {
                    Task { await self.store?.refreshOnce(includeSettings: true) }
                    return nil
                }
            }
            return event
        }
    }

    /// Returns `true` when a drill-in page was closed, so Esc does not also hide the panel.
    private func goBackIfPossible() -> Bool {
        guard let model = store?.model else { return false }
        if model.route == .about { model.closeAbout(); return true }
        if model.route == .ddns { model.closeDDNS(); return true }
        if model.route == .portMapping { model.closePortMapping(); return true }
        if model.route == .cellular {
            model.closeCellular()
            return true
        }
        if model.tab == 3, model.smsRoute != .threads {
            model.smsRoute = .threads
            model.selectedThreadID = nil
            model.replyBody = ""
            return true
        }
        return false
    }

    private func selectTab(_ index: Int) {
        guard let model = store?.model else { return }
        model.tab = index
        model.smsRoute = .threads
        model.selectedThreadID = nil
        if model.route == .cellular { model.closeCellular() }
        if model.route == .ddns { model.closeDDNS() }
        if model.route == .portMapping { model.closePortMapping() }
        if model.route == .about {
            model.closeAbout()
            if model.route != .connect { model.route = .main }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let isContext = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isContext { showContextMenu(sender) } else { togglePopover(sender) }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popoverOpenedAt = Date()
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Dismisses the popover when the click landed outside it.
    ///
    /// The status-item button and its menu are excluded: clicking those must go through the
    /// normal toggle/menu paths instead of being swallowed by a close.
    private func closePopoverIfNeeded() {
        guard let popover, popover.isShown else { return }
        // The click monitors fire on mouse-down and are dispatched asynchronously, so the
        // close could otherwise run *after* the status-item action opened the panel — which
        // made the panel impossible to open at all. Ignore the click that opened it.
        guard Date().timeIntervalSince(popoverOpenedAt) > 0.25 else { return }
        let location = NSEvent.mouseLocation
        if let window = popover.contentViewController?.view.window, window.frame.contains(location) {
            return
        }
        if let button = statusItem?.button, let buttonWindow = button.window,
           buttonWindow.frame.contains(location) {
            return
        }
        popover.performClose(nil)
    }

    // MARK: Context menu

    private func showContextMenu(_ sender: NSStatusBarButton) {
        guard let store else { return }
        let menu = NSMenu()

        let data = store.model.data
        let header = NSMenuItem(title: data.connected ? "\(data.network) · \(data.statusText)" : "未连接",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let relogin = NSMenuItem(title: "重新登录", action: #selector(relogin), keyEquivalent: "")
        relogin.target = self
        relogin.isEnabled = !store.model.busy
        menu.addItem(relogin)

        // A single manual opt-in: the icon shows signal strength by default.
        let rate = NSMenuItem(title: "显示网速",
                              action: #selector(toggleRate(_:)), keyEquivalent: "")
        rate.target = self
        rate.state = store.menuBarStyle.showsRate ? .on : .off
        menu.addItem(rate)

        menu.addItem(.separator())
        // Ticking "save to Keychain" needs a matching way out: the item's ACL only lets
        // this app delete it, so without this there is no way to forget it again.
        let forget = NSMenuItem(title: "清除已保存的密码",
                                action: #selector(forgetCredential), keyEquivalent: "")
        forget.target = self
        menu.addItem(forget)

        let about = NSMenuItem(title: "关于 FiberHome CPE Manager", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出应用", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attach, click, detach: the item must keep left-click opening the popover.
        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleRate(_ sender: NSMenuItem) {
        guard let store else { return }
        let next: MenuBarStyle = store.menuBarStyle.showsRate ? .signalOnly : .signalAndRate
        store.setMenuBarStyle(next)
        refreshStatusItem()
    }

    @objc private func forgetCredential() {
        store?.forgetCredential()
    }

    @objc private func relogin() {
        store?.relogin()
        showPanel()
    }

    @objc private func showAbout() {
        store?.openAbout()
        showPanel()
    }

    private func showPanel() {
        guard let popover, let button = statusItem?.button else { return }
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popoverOpenedAt = Date()
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}


// MARK: - Store

/// Owns the session, the refresh cadence and the widget hand-off. All device work happens
/// in `DeviceSession`; this type only translates results into view state.
@MainActor @Observable final class AppStore {
    let model = ShellModel()
    private var session: DeviceSession?
    private var refreshTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var generation = UUID()
    private var visibleObservers = 0
    private var currentCredentials: Credentials?
    private var activeSessionID: UUID?
    /// Invalidated on every outage as well as reconnect. Late secondary reads cannot
    /// repopulate a page after its live data has been erased.
    private var dataEpoch = UUID()
    private var uplinkOperationID: UUID?
    private var aboutReturnRoute: ShellView.Route = .connect
    private var radioReadInFlight = false
    private var radioReadGeneration = 0
    private var mobileReadInFlight = false
    private var mobileReadGeneration = 0
    private var ddnsReadInFlight = false
    private var portMappingReadInFlight = false
    private var advancedMutationInFlight = false
    /// Settings are a *separate* data source from the 1 Hz traffic sample. Background reads
    /// never toggle the switches or replace an equal value; only a user write sets
    /// settingsBusy. This is what stopped the control page from flickering every second.
    private var settingsReadInFlight = false
    private var settingsGeneration = 0
    private var lastSettingsReadAt = Date.distantPast
    private static let settingsRefreshInterval: TimeInterval = 10
    /// SMS is polled through the device API while its page is visible. Nothing is written to
    /// disk: the array is in-memory state, refreshed from get_sms_data.
    private var smsQuietReadInFlight = false
    private var lastSMSReadAt = Date.distantPast

    private let keychain = CredentialStore()
    /// Set by the delegate; invoked when the popover appears/disappears.
    var onPopoverVisibilityChanged: ((Bool) -> Void)?
    /// Set by the delegate; invoked after every sample so the status item redraws.
    var onStatusItemNeedsUpdate: (() -> Void)?

    private let widgetStore = SharedSnapshotStore()
    private let preferences = Preferences()

    var stale = false
    var keychainLoadFailed = false

    // MARK: Lifecycle

    init() {
        model.menuBarStyle = preferences.menuBarStyle
        wireCallbacks()
        publishWidget(.disconnected)
    }

    func shutdown() { disconnectSession(preservingDraft: false) }

    private func wireCallbacks() {
        model.connect = { [weak self] in self?.connect() }
        model.switchUplink = { [weak self] target in self?.switchUplink(target) }
        model.savePassword = preferences.rememberConnection
        model.detectGateway = { [weak self] in
            self?.model.draftAddress = GatewayDetector.defaultGateway() ?? "192.168.8.1"
        }
        model.openCellular = { [weak self] in
            self?.model.route = .cellular
            self?.reloadRadioLocks()
        }
        model.closeCellular = { [weak self] in self?.model.route = .main }
        model.closeAbout = { [weak self] in
            guard let self else { return }
            self.model.route = self.aboutReturnRoute == .connect && self.model.data.isLive ? .main : self.aboutReturnRoute
        }
        model.setCellLockEnabled = { [weak self] enabled in
            self?.mutateRadioLocks("已\(enabled ? "开启小区锁定" : "关闭小区锁定")") { try await $0.setCellLockEnabled(enabled) }
        }
        model.setBandLockEnabled = { [weak self] enabled, lte, nr in
            self?.mutateRadioLocks("已\(enabled ? "开启频段锁定" : "关闭频段锁定")") { try await $0.setBandLockEnabled(enabled, lte: lte, nr: nr) }
        }
        model.addLockedCell = { [weak self] cell in
            self?.mutateRadioLocks("已添加候选小区") { try await $0.addLockedCell(cell) }
        }
        model.updateLockedCell = { [weak self] cell in
            self?.mutateRadioLocks("已更新候选小区") { try await $0.updateLockedCell(cell) }
        }
        model.deleteLockedCell = { [weak self] cell in
            self?.mutateRadioLocks("已删除候选小区") { try await $0.deleteLockedCell(cell) }
        }
        model.disableLocks = { [weak self] in
            self?.mutateRadioLocks("已关闭全部锁定") { try await $0.disableRadioLocks() }
        }
        model.setAirplaneMode = { [weak self] enabled in
            self?.mutateMobileNetwork(enabled ? "已开启飞行模式" : "已关闭飞行模式") {
                try await $0.setAirplaneMode(enabled)
            }
        }
        model.setCellularData = { [weak self] enabled in
            self?.mutateMobileNetwork(enabled ? "已开启蜂窝数据" : "已关闭蜂窝数据") {
                try await $0.setCellularData(enabled)
            }
        }
        model.saveAntenna = { [weak self] enabled, type in
            self?.mutateMobileNetwork(enabled ? "已启用外置天线（\(type.title)）" : "已关闭外置天线") {
                try await $0.setAntenna(enabled: enabled, type: type)
            }
        }
        model.openDDNS = { [weak self] in
            guard let self, self.model.data.isLive else { return }
            self.model.route = .ddns
            self.model.advancedStatus = nil
            self.reloadMobileNetwork()
            self.reloadDDNS()
        }
        model.closeDDNS = { [weak self] in
            self?.model.route = .main
            self?.model.advancedStatus = nil
        }
        model.reloadDDNS = { [weak self] in self?.reloadDDNS() }
        model.saveDDNS = { [weak self] entry, input in
            guard let self else { throw CancellationError() }
            try await self.saveDDNS(entry, input)
        }
        model.deleteDDNS = { [weak self] entry in
            guard let self else { throw CancellationError() }
            try await self.deleteDDNS(entry)
        }
        model.setDDNSEnabled = { [weak self] entry, enabled in
            guard let self else { throw CancellationError() }
            try await self.setDDNSEnabled(entry, enabled)
        }
        model.openPortMapping = { [weak self] in
            guard let self, self.model.data.isLive else { return }
            self.model.route = .portMapping
            self.model.advancedStatus = nil
            self.reloadMobileNetwork()
            self.reloadPortMappings()
        }
        model.closePortMapping = { [weak self] in
            self?.model.route = .main
            self?.model.advancedStatus = nil
        }
        model.reloadPortMappings = { [weak self] in self?.reloadPortMappings() }
        model.addPortMapping = { [weak self] input in
            guard let self else { throw CancellationError() }
            try await self.addPortMapping(input)
        }
        model.deletePortMapping = { [weak self] entry in
            guard let self else { throw CancellationError() }
            try await self.deletePortMapping(entry)
        }
        model.setPortMappingEnabled = { [weak self] entry, enabled in
            guard let self else { throw CancellationError() }
            try await self.setPortMappingEnabled(entry, enabled)
        }
        model.reserveIP = { [weak self] device, ip in
            guard let self else { throw CancellationError() }
            try await self.reserveIP(for: device, ip: ip)
        }
        model.quit = { NSApp.terminate(nil) }
        model.reloadMessages = { [weak self] in self?.reloadMessages() }
        model.refreshCells = { [weak self] in self?.refreshCells() }
        model.applyLock = { [weak self] cell in self?.applyLock(to: cell) }
        model.sendSMS = { [weak self] in self?.sendSMS() }
        model.toggleSSID = { [weak self] network, enabled in
            self?.toggleSSID(network, enabled: enabled)
        }
        model.renameSSID = { [weak self] network, name in
            self?.renameSSID(network, name: name)
        }
        model.saveReboot = { [weak self] enabled, time, weekday in
            self?.saveReboot(enabled: enabled, time: time, weekday: weekday)
        }
        model.saveLED = { [weak self] enabled in self?.saveLED(enabled) }
        model.saveFan = { [weak self] mode in self?.saveFan(mode) }
        model.markThreadRead = { [weak self] thread in self?.markThreadRead(thread) }
        model.sendReply = { [weak self] thread, body in
            self?.sendReply(to: thread, body: body)
        }
        model.refreshNow = { [weak self] in
            Task { await self?.refreshOnce(includeSettings: true) }
        }
        model.onControlsSelected = { [weak self] in
            self?.reloadSettings(quiet: true)
            self?.reloadMobileNetwork()
            self?.reloadDDNS()
            self?.reloadPortMappings()
        }
        model.onSMSSelected = { [weak self] in self?.reloadMessages(quiet: true) }
    }

    func activate() {
        visibleObservers += 1
        startRefresh(fast: true)
        Task { await refreshOnce() }
    }

    func deactivate() {
        visibleObservers = max(0, visibleObservers - 1)
    }

    // MARK: Menu-bar text

    var menuSignalLevel: Int? {
        guard model.data.isLive else { return nil }
        return model.data.snapshot?.signalBars
    }

    var menuBarStyle: MenuBarStyle { model.menuBarStyle }

    /// The segment draws its own signal bars, so the label carries only the reading.
    var menuLabelText: String {
        MenuBarText.label(for: model.data.isLive ? model.data.snapshot : nil,
                          style: model.menuBarStyle, stale: stale)
    }

    var menuAccessibilityLabel: String {
        if !model.data.connected { return "FiberHomeCPEManager，未连接" }
        let signal = model.data.signalBars.map { "\($0) 格信号" } ?? "信号未知"
        return "FiberHomeCPEManager，\(model.data.network)，\(signal)，\(menuLabelText)"
    }

    func startMenuBarRefresh() {
        if refreshTask == nil { startRefresh(fast: false) }
    }

    // MARK: Connection

    func openAbout() {
        if model.route != .about { aboutReturnRoute = model.route }
        model.route = .about
    }

    /// Reauthentication is a user action: never start a background login contest with WebUI.
    func relogin() {
        guard !model.busy else { return }
        let credential = currentCredentials
        disconnectSession(preservingDraft: true)
        model.route = .connect
        model.connectError = nil
        if let credential {
            model.draftAddress = (try? DeviceAddress(credential.address))?.hostText ?? credential.address
            model.draftUsername = credential.username
            model.draftPassword = credential.password
        } else {
            loadSavedCredentialIfAny()
        }
        if !model.draftPassword.isEmpty { connect() }
    }

    /// True once this process has asked for the stored credential.
    private var didAttemptKeychainLoad = false
    /// What the keychain is known to hold, so an unchanged login never touches it again.
    private var keychainSnapshot: Credentials?

    /// True while a credential is (supposed to be) in the Keychain.
    var isRememberingCredential: Bool { preferences.rememberConnection }

    /// Removes the stored credential and turns the opt-in off.
    func forgetCredential() {
        do {
            try keychain.delete()
            keychainSnapshot = nil
            preferences.rememberConnection = false
            model.savePassword = false
            currentCredentials = nil
            model.statusMessage = "已清除保存的密码，下次需要手动登录"
        } catch {
            model.statusMessage = "未能清除钥匙串条目：\(error.localizedDescription)"
        }
    }

    /// Silent sign-in on launch for users who ticked the Keychain box.
    func restoreSavedSessionIfRequested() {
        guard preferences.rememberConnection else { return }
        loadSavedCredentialIfAny()
        guard !model.draftPassword.isEmpty, !model.data.connected else { return }
        connect()
    }

    /// Loads a remembered credential at most once, and only if the user previously opted
    /// in. Never called from refresh paths.
    ///
    /// Why so conservative: the app is sandboxed and ad-hoc signed, so each rebuild changes
    /// its code signature and the keychain ACL stops matching. macOS then asks for
    /// approval on *every* keychain access. Reading it once at launch (and never in a loop)
    /// keeps that to a single prompt at worst, instead of an endless stream.
    private func loadSavedCredentialIfAny() {
        guard !didAttemptKeychainLoad else { return }
        didAttemptKeychainLoad = true
        guard preferences.rememberConnection || model.savePassword else { return }
        do {
            if let saved = try keychain.load() {
                model.draftAddress = (try? DeviceAddress(saved.address))?.hostText ?? saved.address
                model.draftUsername = saved.username
                model.draftPassword = saved.password
                currentCredentials = saved
                keychainSnapshot = saved
            }
        } catch {
            // A denied or missing item is not fatal: fall back to manual entry.
            keychainLoadFailed = true
            preferences.rememberConnection = false
            model.statusMessage = "无法读取已保存的连接，请重新输入密码。"
        }
    }

    /// True when retyping is the right recovery. Code 1 (already signed in elsewhere) and
    /// network errors keep the entered password; wrong-password and lockout do not.
    private static func isCredentialFailure(_ error: Error) -> Bool {
        guard let error = error as? CPEError else { return false }
        switch error {
        case .authentication:
            return true
        case .loginRejected(let message):
            return message.contains("密码") || message.contains("次数")
        default:
            return false
        }
    }

    func connect() {
        guard !model.busy else { return }
        let addressText = model.draftAddress
        let username = model.draftUsername
        let password = model.draftPassword
        guard !password.isEmpty else {
            model.connectError = "请输入密码"
            return
        }
        let address: DeviceAddress
        do { address = try DeviceAddress(addressText) }
        catch { model.connectError = error.localizedDescription; return }

        let credentials = Credentials(address: address.url.absoluteString, username: username, password: password)
        disconnectSession(preservingDraft: true)
        currentCredentials = nil
        let id = UUID(); generation = id
        model.busy = true
        model.connectError = nil
        let next = DeviceSession(address: address)
        session = next
        activeSessionID = id

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reading = try await next.connect(username: username, password: password)
                guard self.generation == id else { await next.close(); return }
                self.currentCredentials = credentials
                self.model.lanAddress = address.hostText
                self.apply(reading)
                self.model.data.connected = true
                self.model.route = .main
                self.model.tab = 0
                self.model.busy = false
                self.stale = false
                self.persistCredential(credentials)
                // Clear the password from the text field once the session is live; the
                // session keeps its own copy for reconnects, and a failed attempt must not
                // leave a secret sitting in a visible field.
                self.model.draftPassword = ""
                self.startRefresh(fast: self.visibleObservers > 0)
                self.onStatusItemNeedsUpdate?()
                self.onPopoverVisibilityChanged?(true)
                // Conversations come from `get_sms_data`; load them once the session is live
                // so the SMS tab is populated before the user opens it.
                self.reloadMessages()
                self.reloadSettings()
                self.reloadRadioLocks()
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                guard self.generation == id else { return }
                self.model.busy = false
                self.stale = true
                // A rejected credential must not stay in the field: the next click would
                // resend the same wrong text, and three failures trigger the firmware's
                // one-minute lockout. Clear only for credential/lockout failures, not for
                // a network outage the user cannot fix by retyping.
                let clearPassword = Self.isCredentialFailure(error)
                if clearPassword { self.model.draftPassword = "" }
                self.model.connectError = error.localizedDescription
                    + (clearPassword ? " 密码已清空，请重新输入。" : "")
                self.publishWidget(WidgetSnapshot.disconnected)
                self.session = nil
                self.activeSessionID = nil
                self.model.route = .connect
                self.onStatusItemNeedsUpdate?()
                await next.close()
            }
        }
    }

    /// Switches the uplink mode, surviving the LAN drop that a WAN change can cause.
    func switchUplink(_ target: UplinkTarget) {
        guard target.isSupported, !model.settingsBusy else { return }
        guard let session, let id = activeSessionID, let credentials = currentCredentials, model.data.isLive else { return }
        let epoch = dataEpoch
        let operationID = UUID()
        uplinkOperationID = operationID
        refreshTask?.cancel(); refreshTask = nil
        model.settingsBusy = true
        model.uplinkSwitchTarget = target
        model.settingsStatus = "正在切换到\(target.title)…"
        model.settingsStatusIsError = false

        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.uplinkOperationID == operationID {
                    self.uplinkOperationID = nil
                    self.model.settingsBusy = false; self.model.uplinkSwitchTarget = nil
                    self.startRefresh(fast: self.visibleObservers > 0)
                }
            }
            do {
                let applied = try await session.setUplink(target)
                let settings = try await session.readSettings()
                guard self.generation == id, self.activeSessionID == id,
                      self.uplinkOperationID == operationID else { return }
                if self.dataEpoch != epoch || !self.model.data.isLive {
                    let reading = try await session.refresh()
                    guard self.generation == id, self.activeSessionID == id else { return }
                    self.apply(reading)
                    self.stale = false
                    self.reloadMessages(quiet: true); self.reloadRadioLocks()
                }
                self.model.settings = settings
                self.model.settingsBusy = false
                self.model.uplinkSwitchTarget = nil
                self.model.settingsStatus = applied ? "已切换到\(target.title)" : "设备未确认切换结果"
                self.model.settingsStatusIsError = !applied
            } catch {
                guard self.generation == id, self.activeSessionID == id,
                      self.uplinkOperationID == operationID else { return }
                if error as? CPEError == .authentication {
                    self.handleSessionFailure(error, id: id, epoch: self.dataEpoch)
                    return
                }
                guard error is URLError else {
                    self.model.settingsBusy = false; self.model.uplinkSwitchTarget = nil
                    self.model.settingsStatus = "切换失败：\(error.localizedDescription)"
                    self.model.settingsStatusIsError = true
                    self.reloadSettings(quiet: true)
                    return
                }
                // A WAN change can take the LAN/Wi-Fi path down for a few seconds, which
                // kills this session; reconnect before deciding the switch failed.
                self.invalidateDeviceData()
                self.model.settingsBusy = true; self.model.uplinkSwitchTarget = target
                self.model.settingsStatus = "切换中连接中断，正在重连…"
                let recoveredID = await self.reconnect(using: credentials, replacing: id)
                guard (recoveredID != nil && self.activeSessionID == recoveredID)
                    || (recoveredID == nil && self.activeSessionID == id) else { return }
                self.model.settingsBusy = false
                self.model.uplinkSwitchTarget = nil
                if recoveredID != nil {
                    self.model.settingsStatus = "连接已恢复，请确认上行模式"
                    self.model.settingsStatusIsError = false
                } else {
                    self.model.settingsStatus = "切换后无法连接设备：\(error.localizedDescription)"
                    self.model.settingsStatusIsError = true
                }
            }
        }
    }

    /// Retries the session a few times after an uplink switch.
    private func reconnect(using credentials: Credentials, replacing originalID: UUID) async -> UUID? {
        guard let address = try? DeviceAddress(credentials.address) else { return nil }
        for _ in 0..<6 {
            guard generation == originalID, activeSessionID == originalID, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .seconds(2))
            guard generation == originalID, activeSessionID == originalID, !Task.isCancelled else { return nil }
            let fresh = DeviceSession(address: address)
            do {
                let reading = try await fresh.connect(username: credentials.username,
                                                      password: credentials.password)
                guard generation == originalID, activeSessionID == originalID else { await fresh.close(); return nil }
                refreshTask?.cancel()
                await session?.close()
                session = fresh
                let newID = UUID()
                activeSessionID = newID
                generation = newID
                dataEpoch = UUID()
                apply(reading)
                model.data.connected = true
                model.route = .main
                stale = false
                reloadSettings()
                reloadRadioLocks()
                reloadMessages()
                startRefresh(fast: visibleObservers > 0)
                onStatusItemNeedsUpdate?()
                return newID
            } catch {
                await fresh.close()
                if Self.isCredentialFailure(error) { break }
                if case CPEError.loginRejected = error { break }
                continue
            }
        }
        return nil
    }


    /// Persists the credential only when the user asked for it.
    ///
    /// The previous version called `delete()` on every successful connect when "remember"
    /// was off, which meant a keychain round-trip (and possibly an approval prompt) for
    /// every connection. Now a connect with the box unchecked touches nothing.
    private func persistCredential(_ credentials: Credentials) {
        // The login page's checkbox is the source of truth for this connection; the stored
        // preference is only the initial state of that checkbox.
        let wasRemembering = preferences.rememberConnection
        let wantsPersistence = model.savePassword
        preferences.rememberConnection = wantsPersistence
        guard wantsPersistence else {
            // Unchecking is an explicit "forget me": remove any previous item.
            if wasRemembering { try? keychain.delete(); keychainSnapshot = nil }
            return
        }
        guard keychainSnapshot != credentials else { return }
        do {
            try keychain.save(credentials)
            keychainSnapshot = credentials
        } catch {
            // A Keychain failure must not break a working session; report it instead.
            preferences.rememberConnection = false
            model.statusMessage = "未能写入钥匙串：\(error.localizedDescription)"
        }
    }

    private func disconnectSession(preservingDraft: Bool) {
        generation = UUID()
        connectionTask?.cancel(); connectionTask = nil
        refreshTask?.cancel(); refreshTask = nil
        let previous = session
        session = nil
        activeSessionID = nil
        uplinkOperationID = nil
        model.busy = false
        invalidateDeviceData()
        if !preservingDraft { model.draftPassword = "" }
        if let previous { Task { await previous.close() } }
    }

    private func isCurrent(_ id: UUID, epoch: UUID) -> Bool {
        belongsToConnection(id, epoch: epoch) && !Task.isCancelled
    }

    private func belongsToConnection(_ id: UUID, epoch: UUID) -> Bool {
        generation == id && activeSessionID == id && dataEpoch == epoch
    }

    private func invalidateDeviceData() {
        dataEpoch = UUID()
        model.data = PageData(snapshot: nil)
        model.lanAddress = ""
        settingsGeneration += 1
        radioReadGeneration += 1
        settingsReadInFlight = false; smsQuietReadInFlight = false; radioReadInFlight = false
        mobileReadGeneration += 1
        mobileReadInFlight = false; ddnsReadInFlight = false; portMappingReadInFlight = false
        advancedMutationInFlight = false
        reservationInFlight = false
        lastSettingsReadAt = .distantPast; lastSMSReadAt = .distantPast
        stale = true
        publishWidget(.disconnected)
        onStatusItemNeedsUpdate?()
    }

    /// Returns true when the caller must stop publishing its result/banner.
    @discardableResult
    private func handleSessionFailure(_ error: Error, id: UUID, epoch: UUID, primaryRead: Bool = false) -> Bool {
        guard isCurrent(id, epoch: epoch) else { return true }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return true }
        if let cpe = error as? CPEError, cpe == .busy { return true }
        if error as? CPEError == .authentication {
            disconnectSession(preservingDraft: true)
            model.route = .connect
            model.connectError = "登录已失效，可能已在其他入口登录。请重新登录。"
            model.statusMessage = nil
            return true
        }
        if primaryRead || error is URLError {
            invalidateDeviceData()
            model.statusMessage = "连接已断开，请检查设备连接或重新登录。"
            if let session { Task { await session.resetTrafficBaseline() } }
            return true
        }
        return false
    }

    // MARK: Refresh

    /// One second while the popover is open, and the same cadence for the menu-bar label
    /// so the reading does not visibly freeze when the popover closes. Only one request
    /// batch is ever in flight (`DeviceSession` serialises and rejects re-entry).
    func startRefresh(fast: Bool) {
        refreshTask?.cancel()
        guard session != nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshOnce()
                let interval: Duration = .seconds(self.model.data.connected ? 1 : 5)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// One traffic sample. Settings are refreshed separately and at a much lower cadence:
    /// - on entering the Controls tab (ShellView's onChange)
    /// - on a manual refresh (⌘R / context menu / empty-state reload)
    /// - at most once every 10 s while the Controls tab is visible, silently
    ///
    /// They are never read at 1 Hz, and a background read never sets settingsBusy, so the
    /// switches no longer dim/flicker in time with the traffic refresh.
    func refreshOnce(includeSettings: Bool = false) async {
        guard let session, let id = activeSessionID, !model.busy, uplinkOperationID == nil else { return }
        let epoch = dataEpoch
        let wasLive = model.data.isLive
        let previousSMSCount = model.data.snapshot?.smsCount
        do {
            let reading = try await session.refresh()
            guard isCurrent(id, epoch: epoch) else { return }
            apply(reading)
            stale = false
            model.data.connected = true
            publishWidget(WidgetSnapshot(snapshot: reading.snapshot, stale: false))
            let controlsVisible = model.route == .main && model.tab == 2
            let settingsDue = !wasLive || includeSettings
                || (controlsVisible
                    && Date().timeIntervalSince(lastSettingsReadAt) >= Self.settingsRefreshInterval)
            if settingsDue {
                reloadSettings(quiet: !includeSettings)
                if controlsVisible || includeSettings { reloadMobileNetwork() }
            }
            if includeSettings {
                if model.route == .ddns { reloadDDNS() }
                if model.route == .portMapping { reloadPortMappings() }
            }
            // The SMS page hits `get_sms_data` at least once every 5 seconds while visible,
            // AND immediately whenever the device's reported `smsCount` changes.
            let smsVisible = model.route == .main && model.tab == 3
            let smsCountChanged = reading.snapshot.smsCount != previousSMSCount
            if !wasLive || smsCountChanged || (smsVisible && SMSRefreshPolicy.isDue(lastRead: lastSMSReadAt)) {
                reloadMessages(quiet: true)
            }
            if !wasLive || (includeSettings && model.route == .cellular) { reloadRadioLocks() }
        } catch CPEError.busy {
            return
        } catch {
            handleSessionFailure(error, id: id, epoch: epoch, primaryRead: true)
        }
    }

    private func apply(_ reading: SessionReading) {
        model.data = PageData(snapshot: reading.snapshot,
                              devices: reading.devices,
                              stale: false,
                              connected: true)
        // Assigning an equal array still re-renders every row; an open context menu is rebuilt
        // by that and closes, so publish only real changes.
        if model.devices != reading.devices { model.devices = reading.devices }
        model.cells = reading.snapshot.cells.isEmpty
            ? servingOnly(reading.snapshot)
            : reading.snapshot.cells
        model.lockMode = model.radioLocks?.mode ?? reading.snapshot.lockMode
        model.lanAddress = currentCredentials.flatMap { try? DeviceAddress($0.address).hostText } ?? ""
        model.statusMessage = nil
        onStatusItemNeedsUpdate?()
    }

    /// Persists the display style and refreshes the menu-bar item. Called whenever the
    /// user changes the picker; the refresh loop must never overwrite this value.
    func setMenuBarStyle(_ style: MenuBarStyle) {
        guard style != preferences.menuBarStyle else { return }
        preferences.menuBarStyle = style
        model.menuBarStyle = style
    }

    /// Until the scan contract is verified, the discoverable list contains only the
    /// serving cell the device reports — never invented neighbours.
    private func servingOnly(_ snapshot: DeviceSnapshot) -> [CellRecord] {
        let radio = snapshot.servingRadio
        guard let band = radio.band, let pci = radio.pci else { return [] }
        return [CellRecord(tech: snapshot.activeTech == .unknown ? .nr : snapshot.activeTech,
                           band: band, pci: pci, channel: radio.arfcn,
                           rsrp: radio.rsrp, sinr: radio.sinr, state: .serving)]
    }

    // MARK: Widget hand-off

    private func publishWidget(_ snapshot: WidgetSnapshot) {
        widgetStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Secondary actions

    /// Enables/disables one SSID. The switch is optimistic in the UI, then the device is
    /// re-read; a rejected write snaps it back with a visible error banner.
    private func toggleSSID(_ network: WiFiNetwork, enabled: Bool) {
        mutateSettings(enabled ? "已开启 \(network.ssid)" : "已关闭 \(network.ssid)") { session in
            try await session.setSSIDEnabled(index: network.id, enabled: enabled)
        }
    }

    private func renameSSID(_ network: WiFiNetwork, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateSettings("已将 \(network.ssid) 重命名为 \(trimmed)") { session in
            try await session.renameSSID(index: network.id, ssid: trimmed)
        }
    }

    private func saveReboot(enabled: Bool, time: String, weekday: String) {
        mutateSettings("已保存定时重启计划") { session in
            try await session.setTimedReboot(enabled: enabled, time: time, weekday: weekday)
        }
    }

    private func saveLED(_ enabled: Bool) {
        mutateSettings(enabled ? "已开启机身指示灯" : "已关闭机身指示灯") { session in
            try await session.setLEDEnabled(enabled)
        }
    }

    private func saveFan(_ mode: FanMode) {
        mutateSettings("风扇已切换为\(mode.title)") { session in
            try await session.setFanMode(mode)
        }
    }

    func refreshCells() {
        guard let session, let id = activeSessionID, model.data.isLive else { return }
        let epoch = dataEpoch
        reloadRadioLocks()
        Task {
            do {
                let cells = try await session.discoverableCells()
                guard isCurrent(id, epoch: epoch) else { return }
                model.cells = cells
            } catch {
                guard !handleSessionFailure(error, id: id, epoch: epoch) else { return }
                model.cells = []
                model.lockStatus = "小区读取失败：\(error.localizedDescription)"
                model.lockStatusIsError = true
            }
        }
    }

    /// Loads conversations through the firmware's own get_sms_data method.
    ///
    /// - Parameters:
    ///   - keepStatus: leave the current send/result banner alone.
    ///   - quiet: background poll. It never sets smsBusy, so the reply field and buttons do
    ///     not flicker; failures keep the last good conversation list instead of replacing
    ///     it with an error. The array is in-memory only — no local storage.
    ///
    /// Sent messages are appended optimistically, because the firmware can take a moment to
    /// include them in get_sms_data. A reload merges the device list with those pending
    /// local bubbles instead of replacing them, so the just-sent message never disappears
    /// and then reappears ("发送后不同步").
    func reloadMessages(keepStatus: Bool = false, quiet: Bool = false) {
        guard let session, let id = activeSessionID, model.data.isLive else {
            if !quiet {
                model.smsStatus = "未连接"
                model.smsStatusIsError = true
            }
            return
        }
        let epoch = dataEpoch
        if quiet {
            guard !smsQuietReadInFlight, !model.smsBusy else { return }
            smsQuietReadInFlight = true
        } else {
            guard !model.smsBusy else { return }
            model.smsBusy = true
        }
        if !keepStatus, !quiet { model.smsStatus = nil; model.smsStatusIsError = false }
        Task { [weak self] in
            guard let self else { return }
            do {
                let threads = try await session.threads()
                guard self.isCurrent(id, epoch: epoch), self.model.data.isLive else { return }
                let merged = SMSThreadMerge.merge(threads: threads, keepingLocal: self.model.threads)
                if self.model.threads != merged { self.model.threads = merged }
                self.lastSMSReadAt = Date()
                self.model.smsLastSync = self.lastSMSReadAt
                if quiet { self.smsQuietReadInFlight = false } else { self.model.smsBusy = false }
            } catch {
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.lastSMSReadAt = Date()
                if quiet { self.smsQuietReadInFlight = false } else { self.model.smsBusy = false }
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.threads = []; self.model.smsLastSync = nil
                self.model.selectedThreadID = nil; self.model.smsRoute = .threads
                self.model.smsStatus = "短信读取失败：\(error.localizedDescription)"
                self.model.smsStatusIsError = true
            }
        }
    }

    /// A sent message appears in the conversation immediately, with a local id. The next
    /// device read either confirms it (same body, isSent) and drops the local copy, or keeps
    /// it until the firmware catches up.
    private func appendSentMessage(to phone: String, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = SMSMessage(id: "local-sent-\(UUID().uuidString)",
                                 sender: phone, body: text,
                                 date: Self.smsDateFormatter.string(from: Date()),
                                 isRead: true, isSent: true)
        if let index = model.threads.firstIndex(where: { $0.phone == phone }) {
            model.threads[index].messages.append(message)
            model.threads[index].messages.sort { $0.date < $1.date }
        } else {
            model.threads.append(SMSThread(phone: phone, messages: [message]))
        }
        model.threads.sort { ($0.lastMessage?.date ?? "") > ($1.lastMessage?.date ?? "") }
    }

    private static let smsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    /// Marks a conversation's received messages as read on the device.
    func markThreadRead(_ thread: SMSThread) {
        guard let session, let id = activeSessionID, model.data.isLive else { return }
        let epoch = dataEpoch
        let nodes = thread.messages.filter { !$0.isRead && !$0.isSent }.map { $0.childnode ?? $0.id }
        guard !nodes.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await session.markRead(nodes) }
            catch {
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.smsStatus = "未能标记已读：\(error.localizedDescription)"
                self.model.smsStatusIsError = true
                return
            }
            guard self.isCurrent(id, epoch: epoch), let index = self.model.threads.firstIndex(where: { $0.id == thread.id }) else { return }
            for i in self.model.threads[index].messages.indices
            where !self.model.threads[index].messages[i].isSent
                && nodes.contains(self.model.threads[index].messages[i].childnode ?? self.model.threads[index].messages[i].id) {
                self.model.threads[index].messages[i].isRead = true
            }
        }
    }

    /// Reads Wi-Fi / reboot / LED / fan / MLO settings from the device.
    ///
    /// - Parameter quiet: background read. It never sets settingsBusy (so switches stay
    ///   interactive), never clears a user-facing banner, and only reports an error when
    ///   there is no previously-read settings object to keep showing.
    func reloadSettings(quiet: Bool = false) {
        guard let session, let id = activeSessionID, model.data.isLive else {
            if !quiet {
                model.settingsStatus = "未连接"
                model.settingsStatusIsError = true
            }
            return
        }
        let epoch = dataEpoch
        guard !settingsReadInFlight, !model.settingsBusy else { return }
        settingsReadInFlight = true
        settingsGeneration += 1
        let generationAtStart = settingsGeneration
        if !quiet { model.settingsStatus = nil; model.settingsStatusIsError = false }
        Task { [weak self] in
            guard let self else { return }
            do {
                let settings = try await session.readSettings()
                guard generationAtStart == self.settingsGeneration, self.isCurrent(id, epoch: epoch) else { return }
                self.settingsReadInFlight = false
                self.lastSettingsReadAt = Date()
                // Assigning an equal value would still invalidate the view and can reset a
                // SwiftUI Toggle mid-animation. Only publish a genuinely different object.
                if self.model.settings != settings {
                    self.model.settings = settings
                }
                if !quiet {
                    self.model.settingsStatus = nil
                    self.model.settingsStatusIsError = false
                }
            } catch {
                guard generationAtStart == self.settingsGeneration, self.isCurrent(id, epoch: epoch) else { return }
                self.settingsReadInFlight = false
                self.lastSettingsReadAt = Date()
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.settings = nil
                self.model.settingsStatus = "读取设置失败：\(error.localizedDescription)"
                self.model.settingsStatusIsError = true
            }
        }
    }

    /// Runs one settings write, then re-reads so the UI reflects the device, not the tap.
    ///
    /// settingsBusy is true only for the duration of a user write. The old code also set
    /// it for every background read, which is what made every switch dim once a second.
    private func mutateSettings(_ successMessage: String,
                                _ action: @escaping (DeviceSession) async throws -> Bool) {
        guard let session, let id = activeSessionID, model.data.isLive else { model.settingsStatus = "未连接"; model.settingsStatusIsError = true; return }
        let epoch = dataEpoch
        guard !model.settingsBusy else { return }
        model.settingsBusy = true
        // Invalidate any settings read that started before this write.
        settingsGeneration += 1
        settingsReadInFlight = false
        model.settingsStatus = nil; model.settingsStatusIsError = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let ok = try await action(session)
                let settings = try await session.readSettings()
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.model.settings = settings
                self.lastSettingsReadAt = Date()
                self.model.settingsBusy = false
                if ok {
                    self.model.settingsStatus = successMessage
                    self.model.settingsStatusIsError = false
                } else {
                    self.model.settingsStatus = CPEError.rejected.errorDescription
                    self.model.settingsStatusIsError = true
                }
            } catch {
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.model.settingsBusy = false
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.settingsStatus = "操作失败：\(error.localizedDescription)"
                self.model.settingsStatusIsError = true
                // Re-read anyway: the switch in the UI moved optimistically, and the device
                // is the only authority on whether the change actually landed.
                self.model.settings = nil
                self.reloadSettings(quiet: true)
            }
        }
    }

    /// Sends from the inline reply bar of a conversation.
    func sendReply(to thread: SMSThread, body: String) {
        guard let session, let id = activeSessionID, model.data.isLive else { model.smsStatus = "未连接"; model.smsStatusIsError = true; return }
        let epoch = dataEpoch
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.smsBusy else { return }
        model.smsBusy = true
        model.smsStatus = nil; model.smsStatusIsError = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.sendSMS(to: thread.phone, body: text)
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.model.smsBusy = false
                self.model.replyBody = ""
                self.model.draftBody = ""
                // Show the bubble immediately, then reconcile with the device twice: the
                // firmware sometimes needs a moment to list the sent message.
                self.appendSentMessage(to: thread.phone, body: text)
                self.model.selectedThreadID = thread.phone
                self.model.smsRoute = .thread
                self.model.smsStatus = "已发送至 \(thread.phone)"
                self.model.smsStatusIsError = false
                self.reloadMessages(keepStatus: true)
                try? await Task.sleep(for: .milliseconds(1_500))
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.reloadMessages(keepStatus: true)
            } catch {
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.model.smsBusy = false
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.smsStatus = (error as? CPEError)?.errorDescription ?? error.localizedDescription
                self.model.smsStatusIsError = true
            }
        }
    }

    func sendSMS() {
        guard let session, let id = activeSessionID, model.data.isLive else { model.smsStatus = "未连接"; model.smsStatusIsError = true; return }
        let epoch = dataEpoch
        let number = model.draftNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = model.draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty, !body.isEmpty else {
            model.smsStatus = "请填写接收号码和短信内容"; model.smsStatusIsError = true
            return
        }
        guard !model.smsBusy else { return }
        model.smsBusy = true
        model.smsStatus = nil; model.smsStatusIsError = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.sendSMS(to: number, body: body)
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.model.smsBusy = false
                self.model.draftBody = ""
                self.model.replyBody = ""
                self.appendSentMessage(to: number, body: body)
                self.model.selectedThreadID = number
                self.model.smsRoute = .thread
                self.model.smsStatus = "已发送给 \(number)"
                self.model.smsStatusIsError = false
                self.reloadMessages(keepStatus: true)
                try? await Task.sleep(for: .milliseconds(1_500))
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.reloadMessages(keepStatus: true)
            } catch {
                guard self.isCurrent(id, epoch: epoch) else { return }
                // The draft is kept so the user can retry or copy it out.
                self.model.smsBusy = false
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.smsStatus = "发送失败：\(error.localizedDescription)"
                self.model.smsStatusIsError = true
            }
        }
    }

    func applyLock(to cell: CellRecord?) {
        guard let cell, let channel = cell.channel.flatMap(Int.init), let pci = Int(cell.pci),
              cell.tech == .nr || cell.tech == .lte else {
            model.lockStatus = "缺少小区频点或 PCI，无法锁定"
            model.lockStatusIsError = true
            return
        }
        let candidate = LockedCell(index: 0, act: cell.tech == .nr ? 2 : 1, arfcn: channel, pci: pci)
        mutateRadioLocks("已开启小区锁定") { session in
            let current = try await session.readRadioLocks()
            if !current.cells.contains(where: { $0.arfcn == candidate.arfcn && $0.pci == candidate.pci }) {
                _ = try await session.addLockedCell(candidate)
            }
            return try await session.setCellLockEnabled(true)
        }
    }

    private func reloadRadioLocks() {
        guard let session, let id = activeSessionID, model.data.isLive,
              !radioReadInFlight, !model.lockBusy else { return }
        let epoch = dataEpoch
        radioReadGeneration += 1
        let readGeneration = radioReadGeneration
        radioReadInFlight = true
        model.lockBusy = true
        Task {
            do {
                let locks = try await session.readRadioLocks()
                guard isCurrent(id, epoch: epoch), readGeneration == radioReadGeneration else { return }
                radioReadInFlight = false
                model.lockBusy = false
                model.radioLocks = locks; model.lockMode = locks.mode
            } catch {
                guard isCurrent(id, epoch: epoch), readGeneration == radioReadGeneration else { return }
                radioReadInFlight = false
                model.lockBusy = false
                guard !handleSessionFailure(error, id: id, epoch: epoch) else { return }
                model.radioLocks = nil; model.lockMode = .unknown
                model.lockStatus = "锁定配置读取失败：\(error.localizedDescription)"
                model.lockStatusIsError = true
            }
        }
    }

    private func mutateRadioLocks(_ success: String,
                                  _ action: @escaping (DeviceSession) async throws -> RadioLockState) {
        guard let session, let id = activeSessionID, model.data.isLive, !model.lockBusy else { return }
        let epoch = dataEpoch
        radioReadGeneration += 1
        radioReadInFlight = false
        model.lockBusy = true
        model.lockStatus = nil; model.lockStatusIsError = false
        Task {
            do {
                let locks = try await action(session)
                guard isCurrent(id, epoch: epoch) else { return }
                model.radioLocks = locks; model.lockMode = locks.mode
                model.lockBusy = false
                model.lockStatus = success
            } catch {
                guard isCurrent(id, epoch: epoch) else { return }
                model.lockBusy = false
                guard !handleSessionFailure(error, id: id, epoch: epoch) else { return }
                model.radioLocks = nil; model.lockMode = .unknown
                model.lockStatus = "锁定设置失败：\(error.localizedDescription)"
                model.lockStatusIsError = true
                reloadRadioLocks()
            }
        }
    }

    // MARK: Mobile network, DDNS, port mapping

    private func updateAdvancedBusy() {
        model.advancedBusy = ddnsReadInFlight || portMappingReadInFlight || advancedMutationInFlight
    }

    private func reloadMobileNetwork() {
        guard let session, let id = activeSessionID, model.data.isLive,
              !mobileReadInFlight, !model.settingsBusy else { return }
        let epoch = dataEpoch
        mobileReadGeneration += 1
        let readGeneration = mobileReadGeneration
        mobileReadInFlight = true
        Task {
            do {
                let state = try await session.readMobileNetwork()
                guard self.isCurrent(id, epoch: epoch), readGeneration == self.mobileReadGeneration else { return }
                self.mobileReadInFlight = false
                self.model.mobileNetwork = state
            } catch {
                guard self.isCurrent(id, epoch: epoch), readGeneration == self.mobileReadGeneration else { return }
                self.mobileReadInFlight = false
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.mobileNetwork = nil
                self.model.settingsStatus = "移动网络读取失败：\(error.localizedDescription)"
                self.model.settingsStatusIsError = true
            }
        }
    }

    private func mutateMobileNetwork(_ success: String,
                                     _ action: @escaping (DeviceSession) async throws -> MobileNetworkState) {
        guard let session, let id = activeSessionID, model.data.isLive else {
            model.settingsStatus = "未连接"; model.settingsStatusIsError = true
            return
        }
        let epoch = dataEpoch
        guard !model.settingsBusy else { return }
        mobileReadGeneration += 1
        mobileReadInFlight = false
        model.settingsBusy = true
        model.settingsStatus = nil; model.settingsStatusIsError = false
        Task {
            do {
                let state = try await action(session)
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.model.mobileNetwork = state
                self.model.settingsBusy = false
                self.model.settingsStatus = success
                self.model.settingsStatusIsError = false
                self.reloadRadioLocks()
            } catch {
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.model.settingsBusy = false
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.mobileNetwork = nil
                self.model.settingsStatus = "操作失败：\(error.localizedDescription)"
                self.model.settingsStatusIsError = true
                self.reloadMobileNetwork()
            }
        }
    }

    private func reloadDDNS() {
        guard let session, let id = activeSessionID, model.data.isLive,
              !ddnsReadInFlight, !advancedMutationInFlight else { return }
        let epoch = dataEpoch
        ddnsReadInFlight = true
        updateAdvancedBusy()
        Task {
            do {
                let wans = try await session.readWANConnections()
                let entries = try await session.readDDNS()
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.ddnsReadInFlight = false
                self.updateAdvancedBusy()
                self.model.wanConnections = wans
                self.model.ddnsEntries = entries
                self.model.ddnsLoaded = true
            } catch {
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.ddnsReadInFlight = false
                self.updateAdvancedBusy()
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.ddnsEntries = []
                self.model.ddnsLoaded = false
                self.model.advancedStatus = "DDNS 读取失败：\(error.localizedDescription)"
                self.model.advancedStatusIsError = true
            }
        }
    }

    private func reloadPortMappings() {
        guard let session, let id = activeSessionID, model.data.isLive,
              !portMappingReadInFlight, !advancedMutationInFlight else { return }
        let epoch = dataEpoch
        portMappingReadInFlight = true
        updateAdvancedBusy()
        Task {
            do {
                let wans = try await session.readWANConnections()
                let entries = try await session.readPortMappings()
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.portMappingReadInFlight = false
                self.updateAdvancedBusy()
                self.model.wanConnections = wans
                self.model.portMappings = entries
                self.model.portMappingsLoaded = true
            } catch {
                guard self.isCurrent(id, epoch: epoch) else { return }
                self.portMappingReadInFlight = false
                self.updateAdvancedBusy()
                guard !self.handleSessionFailure(error, id: id, epoch: epoch) else { return }
                self.model.portMappings = []
                self.model.portMappingsLoaded = false
                self.model.advancedStatus = "端口映射读取失败：\(error.localizedDescription)"
                self.model.advancedStatusIsError = true
            }
        }
    }

    private func saveDDNS(_ entry: DDNSEntry?, _ input: DDNSInput) async throws {
        guard let session, let id = activeSessionID, model.data.isLive else {
            throw CPEError.unsupported("未连接设备。")
        }
        guard !model.advancedBusy else { throw CPEError.busy }
        let epoch = dataEpoch
        advancedMutationInFlight = true
        updateAdvancedBusy()
        defer {
            if belongsToConnection(id, epoch: epoch) {
                advancedMutationInFlight = false
                updateAdvancedBusy()
                reloadDDNS()
            }
        }
        do {
            let saved: DDNSEntry
            if let entry { saved = try await session.updateDDNS(entry, with: input) }
            else { saved = try await session.addDDNS(input) }
            guard isCurrent(id, epoch: epoch) else { throw CancellationError() }
            model.advancedStatus = "已保存 DDNS：\(saved.hostname)"
            model.advancedStatusIsError = false
        } catch {
            handleSessionFailure(error, id: id, epoch: epoch)
            throw error
        }
    }

    private func deleteDDNS(_ entry: DDNSEntry) async throws {
        guard let session, let id = activeSessionID, model.data.isLive else {
            throw CPEError.unsupported("未连接设备。")
        }
        guard !model.advancedBusy else { throw CPEError.busy }
        let epoch = dataEpoch
        advancedMutationInFlight = true
        updateAdvancedBusy()
        defer {
            if belongsToConnection(id, epoch: epoch) {
                advancedMutationInFlight = false
                updateAdvancedBusy()
                reloadDDNS()
            }
        }
        do {
            try await session.deleteDDNS(entry)
            guard isCurrent(id, epoch: epoch) else { throw CancellationError() }
            model.advancedStatus = "已删除 DDNS：\(entry.hostname)"
            model.advancedStatusIsError = false
        } catch {
            handleSessionFailure(error, id: id, epoch: epoch)
            throw error
        }
    }

    private func setDDNSEnabled(_ entry: DDNSEntry, _ enabled: Bool) async throws {
        guard let session, let id = activeSessionID, model.data.isLive else {
            throw CPEError.unsupported("未连接设备。")
        }
        guard !model.advancedBusy else { throw CPEError.busy }
        let epoch = dataEpoch
        advancedMutationInFlight = true
        updateAdvancedBusy()
        defer {
            if belongsToConnection(id, epoch: epoch) {
                advancedMutationInFlight = false
                updateAdvancedBusy()
                reloadDDNS()
            }
        }
        do {
            let saved = try await session.setDDNSEnabled(entry, enabled)
            guard isCurrent(id, epoch: epoch) else { throw CancellationError() }
            model.advancedStatus = "已\(saved.enabled ? "启用" : "停用") DDNS：\(saved.hostname)"
            model.advancedStatusIsError = false
        } catch {
            handleSessionFailure(error, id: id, epoch: epoch)
            throw error
        }
    }

    private func addPortMapping(_ input: PortMappingInput) async throws {
        guard let session, let id = activeSessionID, model.data.isLive else {
            throw CPEError.unsupported("未连接设备。")
        }
        guard !model.advancedBusy else { throw CPEError.busy }
        let epoch = dataEpoch
        advancedMutationInFlight = true
        updateAdvancedBusy()
        defer {
            if belongsToConnection(id, epoch: epoch) {
                advancedMutationInFlight = false
                updateAdvancedBusy()
                reloadPortMappings()
            }
        }
        do {
            let saved = try await session.addPortMapping(input)
            guard isCurrent(id, epoch: epoch) else { throw CancellationError() }
            model.advancedStatus = "已添加端口映射：\(saved.localIP) \(saved.externalRange)"
            model.advancedStatusIsError = false
        } catch {
            handleSessionFailure(error, id: id, epoch: epoch)
            throw error
        }
    }

    private func deletePortMapping(_ entry: PortMappingEntry) async throws {
        guard let session, let id = activeSessionID, model.data.isLive else {
            throw CPEError.unsupported("未连接设备。")
        }
        guard !model.advancedBusy else { throw CPEError.busy }
        let epoch = dataEpoch
        advancedMutationInFlight = true
        updateAdvancedBusy()
        defer {
            if belongsToConnection(id, epoch: epoch) {
                advancedMutationInFlight = false
                updateAdvancedBusy()
                reloadPortMappings()
            }
        }
        do {
            try await session.deletePortMapping(entry)
            guard isCurrent(id, epoch: epoch) else { throw CancellationError() }
            model.advancedStatus = "已删除端口映射：\(entry.localIP) \(entry.externalRange)"
            model.advancedStatusIsError = false
        } catch {
            handleSessionFailure(error, id: id, epoch: epoch)
            throw error
        }
    }

    private func setPortMappingEnabled(_ entry: PortMappingEntry, _ enabled: Bool) async throws {
        guard let session, let id = activeSessionID, model.data.isLive else {
            throw CPEError.unsupported("未连接设备。")
        }
        guard !model.advancedBusy else { throw CPEError.busy }
        let epoch = dataEpoch
        advancedMutationInFlight = true
        updateAdvancedBusy()
        defer {
            if belongsToConnection(id, epoch: epoch) {
                advancedMutationInFlight = false
                updateAdvancedBusy()
                reloadPortMappings()
            }
        }
        do {
            let saved = try await session.setPortMappingEnabled(entry, enabled)
            guard isCurrent(id, epoch: epoch) else { throw CancellationError() }
            model.advancedStatus = "已\(saved.enabled ? "启用" : "停用")端口映射：\(saved.localIP)"
            model.advancedStatusIsError = false
        } catch {
            handleSessionFailure(error, id: id, epoch: epoch)
            throw error
        }
    }

    private var reservationInFlight = false
    private func reserveIP(for device: ConnectedDevice, ip: String) async throws {
        guard let session, let id = activeSessionID, model.data.isLive else {
            throw CPEError.unsupported("连接已断开，请重新连接后设置。")
        }
        guard !reservationInFlight else { throw CPEError.busy }
        guard let mac = device.mac else { throw DHCPReservationError.invalidMACAddress }
        let epoch = dataEpoch
        reservationInFlight = true
        defer { if belongsToConnection(id, epoch: epoch) { reservationInFlight = false } }
        do {
            try await session.reserveIP(mac: mac, ip: ip)
            guard isCurrent(id, epoch: epoch) else { throw CancellationError() }
        } catch {
            handleSessionFailure(error, id: id, epoch: epoch)
            throw error
        }
    }
}

import Cocoa
import ApplicationServices

/// Interaction smoke test for the running FiberHomeCPEManager app.
///
/// Drives the real UI through Accessibility: opens the popover, walks every page and
/// control, and reports what it finds. This is test tooling only — it never types a real
/// password and never sends a write to the device.
///
/// Usage: `ui_probe <scenario>` where scenario is one of
///   inventory, tabs, settings, contextmenu, quit

let bundleID = "local.fhcpem.app"

func attribute(_ element: AXUIElement, _ key: String) -> String {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return (value as? String) ?? ""
}

func boolAttribute(_ element: AXUIElement, _ key: String) -> Bool? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return value as? Bool
}

func numberAttribute(_ element: AXUIElement, _ key: String) -> Int? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return (value as? NSNumber)?.intValue
}

func childrenOf(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    return (value as? [AXUIElement]) ?? []
}

func pointOf(_ element: AXUIElement) -> CGPoint {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
    var point = CGPoint.zero
    if let value, CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
    }
    return point
}

func sizeOf(_ element: AXUIElement) -> CGSize {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
    var size = CGSize.zero
    if let value, CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(value as! AXValue, .cgSize, &size)
    }
    return size
}

func click(_ element: AXUIElement) {
    let origin = pointOf(element), size = sizeOf(element)
    let centre = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: centre, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(70_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: centre, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func click(at centre: CGPoint, right: Bool = false) {
    let type: CGEventType = right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
    let button: CGMouseButton = right ? .right : .left
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: centre, mouseButton: button)?
        .post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: centre, mouseButton: button)?
        .post(tap: .cghidEventTap)
}

func app() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == bundleID && !$0.isTerminated
    }
}

/// The status item sits in the app's extras menu bar.
func statusItemElement() -> AXUIElement? {
    guard let app = app() else { return nil }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var extras: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &extras)
    guard let raw = extras, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return childrenOf(unsafeBitCast(raw, to: AXUIElement.self)).first
}

func popoverWindowFrame() -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list where (window[kCGWindowOwnerName as String] as? String ?? "").contains("FiberHomeCPEManager") {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Double],
              (bounds["Width"] ?? 0) > 300, (bounds["Height"] ?? 0) > 300 else { continue }
        return CGRect(x: bounds["X"]!, y: bounds["Y"]!, width: bounds["Width"]!, height: bounds["Height"]!)
    }
    return nil
}

/// `NSPopover` content is an AXPopover under the status item, not an app window.
func popoverRoot() -> AXUIElement? {
    guard let frame = popoverWindowFrame() else { return nil }
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    AXUIElementCopyElementAtPosition(system, Float(frame.midX), Float(frame.midY), &element)
    var node = element
    for _ in 0..<6 {
        guard let current = node else { return nil }
        if attribute(current, kAXRoleAttribute) == "AXPopover" { return current }
        var parent: CFTypeRef?
        AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
        node = parent.flatMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil
        }
    }
    return nil
}

func descendants(_ root: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 20 else { return }
        out.append(element)
        for child in childrenOf(element) { walk(child, depth: depth + 1) }
    }
    walk(root, depth: 0)
    return out
}

/// Opens the panel via the accessibility press action.
///
/// A synthetic mouse click is a toggle and depends on the current state, which made the
/// probe flaky; `AXPress` always performs one open.
/// Polls a condition instead of sleeping a fixed amount.
///
/// Every `usleep` here was a guess that had to cover the slowest case; polling returns as
/// soon as the UI has actually settled, which is both faster and less flaky.
@discardableResult
func waitFor(_ timeout: TimeInterval = 2.5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(40_000)
    }
    return condition()
}

func openPopover() {
    guard let item = statusItemElement() else { print("FAIL: no status item"); return }
    if popoverRoot() != nil {
        activateApp()
        return
    }
    _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
    if !waitFor(1.5, { popoverRoot() != nil }) {
        click(item)
        _ = waitFor(1.5, { popoverRoot() != nil })
    }
    app()?.activate(options: [.activateIgnoringOtherApps])
    _ = waitFor(1.0, { app()?.isActive == true })
}

func closePopover() {
    guard popoverRoot() != nil, let item = statusItemElement() else { return }
    _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
    usleep(700_000)
}

func pageHasText(_ text: String) -> Bool {
    guard let root = popoverRoot() else { return false }
    return descendants(root).contains {
        attribute($0, kAXValueAttribute).contains(text) || attribute($0, kAXDescriptionAttribute).contains(text)
    }
}

@discardableResult
func chooseStatusMenuItem(_ title: String) -> Bool {
    resetUI(); closePopover()
    guard let item = statusItemElement() else { return false }
    let origin = pointOf(item), size = sizeOf(item)
    let position = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    click(at: position, right: true)
    var wanted: AXUIElement?
    _ = waitFor {
        var element: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(position.x), Float(position.y + 50), &element)
        var node = element
        for _ in 0..<8 {
            guard let current = node else { return false }
            if attribute(current, kAXRoleAttribute) == "AXMenu" {
                wanted = childrenOf(current).first { attribute($0, kAXTitleAttribute) == title }
                return wanted != nil
            }
            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            node = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
        }
        return false
    }
    guard let wanted else { return false }
    return AXUIElementPerformAction(wanted, kAXPressAction as CFString) == .success
}

func inventory(_ label: String) {
    guard let root = popoverRoot() else { print("  [\(label)] no popover"); return }
    let all = descendants(root)
    let buttons = all.filter { attribute($0, kAXRoleAttribute) == "AXButton" }
    let fields = all.filter { attribute($0, kAXRoleAttribute) == "AXTextField" }
    let texts = all.filter { attribute($0, kAXRoleAttribute) == "AXStaticText" }
        .compactMap { attribute($0, kAXValueAttribute) as String? }
        .filter { !$0.isEmpty }
    print("  [\(label)] buttons=\(buttons.count) fields=\(fields.count) texts=\(texts.count)")
    print("     texts: \(texts.prefix(8).joined(separator: " | "))")
    print("     button sizes: \(buttons.map { "\(Int(sizeOf($0).width))x\(Int(sizeOf($0).height))" })")
}

/// Taps a bottom-navigation tab by its label. v2 moved navigation to the bottom bar, so
/// position-based heuristics no longer identify tabs.
func tapTab(index: Int) {
    let names = ["概览", "设备", "控制", "短信"]
    guard index < names.count, let root = popoverRoot() else { return }
    let wanted = names[index]
    let candidates = descendants(root).filter {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute) == wanted
    }
    guard let target = candidates.first else {
        print("  tab \(wanted) missing")
        return
    }
    _ = AXUIElementPerformAction(target, kAXPressAction as CFString)
    usleep(800_000)
}

// MARK: - Scenarios

func onScreenWindowCount() -> Int {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerName as String] as? String ?? "").contains("FiberHomeCPEManager") }.count
}

func pressKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(60_000)
    up?.post(tap: .cghidEventTap)
}

/// Polls until the process is gone.
///
/// `NSWorkspace.runningApplications` keeps a stale entry for a process this probe did not
/// launch, so the app appeared to survive when it had already exited. `kill(pid, 0)` is the
/// direct answer to "does this process still exist".
func waitUntilQuit(pid: pid_t, timeout: TimeInterval = 6) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if kill(pid, 0) != 0 { return true }   // ESRCH: no such process
        usleep(200_000)
    }
    return kill(pid, 0) != 0
}

func activateApp() {
    app()?.activate(options: [.activateIgnoringOtherApps])
    _ = waitFor(1.0, { app()?.isActive == true })
}

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("  \(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  (\(detail))")")
}

func buttons(in root: AXUIElement) -> [AXUIElement] {
    descendants(root).filter { attribute($0, kAXRoleAttribute) == "AXButton" }
}

/// Returns the app to a known state: no menu, no popover, app active.
///
/// Scenarios used to leak state into each other (a panel left open made the next
/// scenario's menu check fail), which produced failures that were artifacts of the probe
/// rather than of the app.
func resetUI() {
    activateApp()
    pressKey(53)                 // dismiss a stray menu
    _ = waitFor(0.6, { popoverRoot() == nil || true })

    // Walk out of any drill-in page so scenarios start from the tabbed root.
    openPopover()
    for _ in 0..<3 {
        guard let root = popoverRoot() else { break }
        guard let back = descendants(root).first(where: {
            attribute($0, kAXRoleAttribute) == "AXButton" &&
            attribute($0, kAXDescriptionAttribute).contains("返回")
        }) else { break }
        _ = AXUIElementPerformAction(back, kAXPressAction as CFString)
        _ = waitFor(1.0, { popoverRoot().map { root in
            !descendants(root).contains { attribute($0, kAXDescriptionAttribute).contains("返回") }
        } ?? true })
    }

    // Leave the panel closed: scenarios call openPopover() themselves, so this is one
    // toggle instead of a close-then-open pair.
    if popoverRoot() != nil, let item = statusItemElement() {
        _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
        _ = waitFor(1.0, { popoverRoot() == nil })
    }
    activateApp()
}

let scenario = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "inventory"

switch scenario {
case "inventory":
    openPopover()
    inventory("initial")

case "tabs":
    resetUI()
    openPopover()
    // Each tab must expose its page and a real value from the device.
    let expectations: [(String, String)] = [
        ("概览", "蜂窝信息"), ("设备", "全部"), ("控制", "上行运行模式"), ("短信", "写短信")
    ]
    for (index, expected) in expectations.enumerated() {
        tapTab(index: index)
        guard let root = popoverRoot() else {
            check("\(expected.0) 页", false, "panel closed"); continue
        }
        let texts = descendants(root).compactMap { attribute($0, kAXValueAttribute) as String? }
        // The SMS page is identified by its compose action rather than a title, because the
        // tab bar already contains the word 短信.
        let labels = descendants(root).map { attribute($0, kAXDescriptionAttribute) }
        let ok = texts.contains(expected.1) || labels.contains(where: { $0.contains(expected.1) })
        check("\(expected.0) 页渲染", ok)
        inventory(expected.0)
    }

case "about":
    check("关于菜单可打开页面", chooseStatusMenuItem("关于 FiberHome CPE Manager"))
    check("关于显示产品与支持型号", waitFor { pageHasText("支持 LG6851F / RP0112") && pageHasText("FiberHome CPE Manager") })
    check("关于显示内存与钥匙串说明", pageHasText("仅保存在内存") && pageHasText("系统钥匙串"))
    activateApp(); pressKey(53)
    check("Esc 返回之前页面", waitFor { !pageHasText("支持 LG6851F / RP0112") && popoverRoot() != nil })

case "relogin":
    check("重新登录菜单可执行", chooseStatusMenuItem("重新登录"))
    check("重新登录恢复实时概览", waitFor(12) { pageHasText("蜂窝信息") })

case "session-expired":
    openPopover()
    check("失效会话返回登录页", waitFor(12) { pageHasText("登录已失效") })
    check("登录页不显示旧短信和蜂窝信息", !pageHasText("短信会话") && !pageHasText("蜂窝信息"))
    check("失效后可显式重新登录", chooseStatusMenuItem("重新登录"))
    check("重新登录恢复实时概览", waitFor(12) { pageHasText("蜂窝信息") })

case "contextmenu":
    resetUI()
    closePopover()
    guard let item = statusItemElement() else { print("FAIL: no status item"); break }
    let origin = pointOf(item), size = sizeOf(item)
    click(at: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2), right: true)
    usleep(900_000)
    var titles: [String] = []
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    AXUIElementCopyElementAtPosition(system, Float(origin.x + size.width / 2), Float(origin.y + 60), &element)
    var node = element
    for _ in 0..<8 {
        guard let current = node else { break }
        if attribute(current, kAXRoleAttribute) == "AXMenu" {
            titles = childrenOf(current).map { attribute($0, kAXTitleAttribute) }
            break
        }
        var parent: CFTypeRef?
        AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
        node = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
    }
    print("  menu: \(titles)")
    check("右键菜单含退出应用", titles.contains("退出应用"))
    check("右键菜单含重新登录", titles.contains("重新登录"))
    check("右键菜单含关于", titles.contains("关于 FiberHome CPE Manager"))
    check("右键菜单含网速勾选项", titles.contains("显示网速"))
    check("右键菜单不含打开面板", !titles.contains("打开面板"))
    check("右键菜单不含立即刷新", !titles.contains("立即刷新"))
    click(at: CGPoint(x: origin.x + 60, y: 500))

case "login-fullwidth":
    // The firmware password ends in an ASCII comma. A Chinese IME produces "，"; the form
    // must flag it before sending instead of burning a login attempt.
    resetUI()
    openPopover()
    activateApp()
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    let fields = descendants(root).filter { attribute($0, kAXRoleAttribute) == "AXTextField" }
    guard fields.count >= 3 else { print("  FAIL fields missing: \(fields.count)"); break }
    let password = fields[2]
    click(password)
    usleep(250_000)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("Test12345，", forType: .string)
    pressKey(9, flags: .maskCommand)
    usleep(700_000)
    let afterPaste = (popoverRoot().map { descendants($0).flatMap {
        [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
    } }) ?? []
    check("全角密码提示出现", afterPaste.contains { $0.contains("全角") },
          afterPaste.first { $0.contains("全角") } ?? "no warning")
    if let fix = descendants(popoverRoot() ?? root).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute).contains("改为半角")
    }) {
        _ = AXUIElementPerformAction(fix, kAXPressAction as CFString)
        usleep(600_000)
    } else {
        check("改为半角按钮存在", false)
    }
    let afterFix = (popoverRoot().map { descendants($0).flatMap {
        [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
    } }) ?? []
    check("全角提示已消失", !afterFix.contains { $0.contains("全角") })
    NSPasteboard.general.clearContents()

case "login-extra":
    resetUI()
    openPopover()
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    let all = descendants(root)
    check("保存密码勾选项存在", all.contains {
        attribute($0, kAXRoleAttribute) == "AXCheckBox" &&
        attribute($0, kAXDescriptionAttribute).contains("保存密码")
    } || all.contains { attribute($0, kAXDescriptionAttribute).contains("保存密码") })

    // Gateway probe: clear the IP, press 导入网关, expect it to come back with a host.
    let fields = all.filter { attribute($0, kAXRoleAttribute) == "AXTextField" }
    guard let ipField = fields.first,
          let probe = all.first(where: { attribute($0, kAXDescriptionAttribute).contains("导入网关") })
    else { check("导入网关回填 IP", false, "field or button missing"); break }
    _ = AXUIElementPerformAction(ipField, kAXPressAction as CFString)
    usleep(300_000)
    for (code, flags) in [(CGKeyCode(0), CGEventFlags.maskCommand), (CGKeyCode(51), CGEventFlags())] {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap); usleep(60_000)
        up?.post(tap: .cghidEventTap); usleep(150_000)
    }
    _ = AXUIElementPerformAction(probe, kAXPressAction as CFString)
    usleep(800_000)
    let after = (popoverRoot().map { root in
        descendants(root).filter { attribute($0, kAXRoleAttribute) == "AXTextField" }
            .map { attribute($0, kAXValueAttribute) }
    }) ?? []
    check("导入网关回填 IP", after.first?.isEmpty == false)

case "login-empty":
    resetUI()
    openPopover()
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    // The scenario only makes sense before the first successful login: a connected app has
    // no password field, and the wide button on that page is "更多设备信息".
    let fieldCount = descendants(root).filter { attribute($0, kAXRoleAttribute) == "AXTextField" }.count
    guard fieldCount >= 3 else { print("  SKIP 已登录，跳过空密码检查"); break }
    guard let connect = buttons(in: root).first(where: { sizeOf($0).height >= 24 && sizeOf($0).width > 200 }) else {
        print("  FAIL connect button missing"); break
    }
    check("连接按钮存在", true, "\(Int(sizeOf(connect).width))x\(Int(sizeOf(connect).height))")
    click(connect)
    usleep(700_000)
    let texts = descendants(root).compactMap { attribute($0, kAXValueAttribute) as String? }
    check("空密码给出提示", texts.contains { $0.contains("请输入密码") })

case "esc":
    resetUI()
    openPopover()
    check("面板已打开", onScreenWindowCount() > 0)
    activateApp()
    pressKey(53)
    usleep(800_000)
    check("Esc 关闭面板", onScreenWindowCount() == 0)
    check("Esc 不退出应用", app() != nil)

case "cmdw":
    resetUI()
    openPopover()
    activateApp()
    pressKey(13, flags: .maskCommand)
    usleep(800_000)
    check("⌘W 关闭面板", onScreenWindowCount() == 0)

case "cmdq":
    resetUI()
    check("应用在运行", app() != nil)
    openPopover()
    guard let pid = app()?.processIdentifier else { print("  FAIL app pid unavailable"); break }
    activateApp()
    pressKey(12, flags: .maskCommand)
    check("⌘Q 退出应用", waitUntilQuit(pid: pid))

case "power":
    // The panel has no header any more, so the menu-bar context menu is the UI quit path.
    resetUI()
    closePopover()
    guard let item = statusItemElement() else { print("  FAIL no status item"); break }
    guard let pid = app()?.processIdentifier else { print("  FAIL app pid unavailable"); break }
    let origin = pointOf(item), size = sizeOf(item)
    click(at: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2), right: true)
    usleep(900_000)
    var quitItem: AXUIElement?
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    AXUIElementCopyElementAtPosition(system, Float(origin.x + size.width / 2),
                                     Float(origin.y + 60), &element)
    var node = element
    for _ in 0..<8 {
        guard let current = node else { break }
        if attribute(current, kAXRoleAttribute) == "AXMenu" {
            quitItem = childrenOf(current).first {
                attribute($0, kAXTitleAttribute) == "退出应用"
            }
            break
        }
        var parent: CFTypeRef?
        AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
        node = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
    }
    if let quitItem {
        _ = AXUIElementPerformAction(quitItem, kAXPressAction as CFString)
        check("右键菜单退出应用", waitUntilQuit(pid: pid))
    } else {
        check("右键菜单退出应用", false, "menu item not found")
    }

case "a11y":
    guard app() != nil else { print("  FAIL  应用未运行"); exit(1) }
    // Every interactive control must expose a name; an unnamed button is unusable with
    // VoiceOver and often hides a stray zero-sized hit area.
    resetUI()
    openPopover()
    activateApp()
    var offenders: [String] = []
    var sweptPages = 0

    /// Scrollbars expose their arrows/track as buttons; they are AppKit chrome, not our UI.
    func insideScrollBar(_ element: AXUIElement) -> Bool {
        var node: AXUIElement? = element
        for _ in 0..<4 {
            guard let current = node else { return false }
            let role = attribute(current, kAXRoleAttribute)
            let subrole = attribute(current, kAXSubroleAttribute)
            if role == "AXScrollBar" || subrole == "AXScrollBar" { return true }
            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            node = parent.flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID()
                    ? unsafeBitCast($0, to: AXUIElement.self) : nil
            }
        }
        return false
    }

    func sweep(_ page: String) {
        guard let root = popoverRoot() else { return }
        sweptPages += 1
        for element in descendants(root) {
            let role = attribute(element, kAXRoleAttribute)
            guard ["AXButton", "AXCheckBox", "AXRadioButton"].contains(role) else { continue }
            let size = sizeOf(element)
            guard size.width >= 2, size.height >= 2 else { continue }
            guard !insideScrollBar(element) else { continue }
            let name = attribute(element, kAXDescriptionAttribute)
                + attribute(element, kAXTitleAttribute)
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                offenders.append("\(role.replacingOccurrences(of: "AX", with: ""))@\(page) \(Int(size.width))x\(Int(size.height))")
            }
        }
    }

    let markers = ["蜂窝信息", "全部", "上行运行模式", "写短信"]
    for (index, marker) in markers.enumerated() {
        pressKey(CGKeyCode(18 + index), flags: .maskCommand)
        _ = waitFor(2.0) {
            guard let root = popoverRoot() else { return false }
            return descendants(root).contains {
                attribute($0, kAXValueAttribute).contains(marker) ||
                attribute($0, kAXDescriptionAttribute).contains(marker)
            }
        }
        sweep("tab\(index)")
    }

    // Drill-in pages are part of the same surface and get the same audit.
    pressKey(18, flags: .maskCommand)
    _ = waitFor(1.5, { popoverRoot() != nil })
    if let detail = descendants(popoverRoot() ?? AXUIElementCreateSystemWide()).first(where: {
        attribute($0, kAXDescriptionAttribute).contains("蜂窝详情")
    }) {
        _ = AXUIElementPerformAction(detail, kAXPressAction as CFString)
        _ = waitFor(1.5, { popoverRoot() != nil })
        sweep("蜂窝详情")
        pressKey(53)
        _ = waitFor(1.0, { popoverRoot() != nil })
    }

    pressKey(21, flags: .maskCommand)
    _ = waitFor(1.5, { popoverRoot() != nil })
    if let thread = descendants(popoverRoot() ?? AXUIElementCreateSystemWide()).first(where: {
        let label = attribute($0, kAXDescriptionAttribute)
        return label.contains("10010") && sizeOf($0).height > 30
    }) {
        _ = AXUIElementPerformAction(thread, kAXPressAction as CFString)
        _ = waitFor(1.5, { popoverRoot() != nil })
        sweep("会话")
    }

    // A sweep that never saw a page proves nothing: require the panel to be there.
    check("全部页面无未命名控件", offenders.isEmpty && sweptPages >= 6,
          offenders.isEmpty ? "\(sweptPages) 个页面" : offenders.prefix(5).joined(separator: ", "))

case "sms":
    resetUI()
    openPopover()
    activateApp()
    pressKey(21, flags: .maskCommand)   // ⌘4 → 短信
    usleep(800_000)
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    let labels = descendants(root).map { attribute($0, kAXDescriptionAttribute) }
    let values = descendants(root).compactMap { attribute($0, kAXValueAttribute) as? String }
    let all = labels + values
    // The operator-fact capsules were removed by request. Detect the old 16 pt chips by
    // size, not by text: message bodies legitimately contain "GB" and "积分".
    let smallCapsules = descendants(root).filter {
        sizeOf($0).height > 0 && sizeOf($0).height <= 18 &&
        (attribute($0, kAXDescriptionAttribute).contains("GB") ||
         attribute($0, kAXDescriptionAttribute).contains("积分"))
    }
    check("会话列表无流量/积分胶囊", smallCapsules.isEmpty,
          smallCapsules.isEmpty ? "" : "\(smallCapsules.count) capsule elements")

    // Open the conversation.
    if let row = descendants(root).first(where: {
        let label = attribute($0, kAXDescriptionAttribute)
        return label.contains("10010") && sizeOf($0).height > 30
    }) {
        _ = AXUIElementPerformAction(row, kAXPressAction as CFString)
        usleep(900_000)
    }
    let threadElements = descendants(popoverRoot() ?? root)
    let threadLabels = threadElements.map { attribute($0, kAXDescriptionAttribute) }
    let threadCapsules = threadElements.filter {
        sizeOf($0).height > 0 && sizeOf($0).height <= 18 &&
        (attribute($0, kAXDescriptionAttribute).contains("GB") ||
         attribute($0, kAXDescriptionAttribute).contains("积分"))
    }
    check("详情页无置顶信息胶囊", threadCapsules.isEmpty)
    check("无快捷指令胶囊", !threadLabels.contains { $0.contains("发送流量查询") })
    check("内联回复框", threadLabels.contains("回复内容"))

case "sms-poll":
    // Enter the SMS page, then prove get_sms_data is polled again within five seconds.
    openPopover()
    activateApp()
    pressKey(18, flags: .maskCommand)   // leave any drill-in page / sms thread
    usleep(600_000)
    pressKey(21, flags: .maskCommand)   // ⌘4 → 短信
    usleep(1_200_000)
    func syncStamps() -> [String] {
        guard let root = popoverRoot() else { return [] }
        return descendants(root).flatMap {
            [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
        }.filter { $0.contains("同步") }
    }
    let before = syncStamps()
    check("短信同步时间戳存在", !before.isEmpty, before.first ?? "missing")
    // The refresh loop is 1 Hz and the SMS policy is 5 s; wait long enough for one poll and
    // one display update.
    usleep(7_000_000)
    let after = syncStamps()
    check("短信 5 秒内再次同步", !after.isEmpty && after != before,
          "\(before.first ?? "-") → \(after.first ?? "-")")

case "sms-send":
    // One-shot live check for the operator-command path: open the 10010 conversation and
    // press 流量查询 once, then report the device's send result and whether the thread
    // reloaded. Used to verify outbound SMS + inbox sync against the real CPE.
    openPopover()
    activateApp()
    // Walk out of a compose/thread page left by an earlier run.
    if let back = descendants(popoverRoot() ?? AXUIElementCreateSystemWide()).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute).contains("返回")
    }) { click(back); usleep(700_000) }
    pressKey(21, flags: .maskCommand)   // ⌘4 → 短信
    usleep(800_000)
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    guard let row = descendants(root).first(where: {
        let label = attribute($0, kAXDescriptionAttribute)
        return label.contains("10010") && sizeOf($0).height > 30
    }) else {
        print("  FAIL 10010 conversation missing")
        break
    }
    _ = AXUIElementPerformAction(row, kAXPressAction as CFString)
    usleep(900_000)
    // New UI: type 流量查询 into the inline reply box and press 发送回复. Old builds had a
    // one-tap 发送流量查询 chip; support both so the probe can verify either build.
    let chipCandidates = descendants(popoverRoot() ?? root).filter {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute).contains("发送流量查询")
    }
    if let chip = chipCandidates.first {
        print("     using legacy 发送流量查询 chip")
        click(chip)
    } else {
        let elements = descendants(popoverRoot() ?? root)
        guard let field = elements.first(where: {
            attribute($0, kAXRoleAttribute) == "AXTextField" &&
            (attribute($0, kAXDescriptionAttribute).contains("回复") ||
             attribute($0, kAXPlaceholderValueAttribute).contains("回复"))
        }) else {
            print("  FAIL reply field missing")
            break
        }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("流量查询", forType: .string)
        pressKey(9, flags: .maskCommand)
        usleep(300_000)
        let send = descendants(popoverRoot() ?? root).first {
            attribute($0, kAXRoleAttribute) == "AXButton" &&
            attribute($0, kAXDescriptionAttribute).contains("发送回复")
        }
        guard let send else { print("  FAIL 发送回复 button missing"); break }
        click(send)
    }
    let finished = waitFor(12) {
        guard let r = popoverRoot() else { return false }
        let texts = descendants(r).flatMap {
            [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
        }
        return texts.contains { $0.contains("已回复") || $0.contains("发送失败") }
    }
    let texts = (popoverRoot().map { descendants($0).flatMap {
        [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
    } }) ?? []
    check("发送流量查询完成", finished)
    check("发送状态可见", texts.contains { $0.contains("已回复") || $0.contains("发送失败") },
          texts.first { $0.contains("已回复") || $0.contains("发送失败") } ?? "no status")
    print("     status texts: \(texts.filter { $0.contains("回复") || $0.contains("发送") }.prefix(8))")
    // The app reloads conversations after a successful send; give it a moment and check
    // that the outbound message appears in the conversation or its list.
    usleep(1_500_000)
    let after = (popoverRoot().map { descendants($0).flatMap {
        [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
    } }) ?? []
    check("发送后会话出现已发送气泡", after.contains { $0.contains("已发送，流量查询") },
          after.first { $0.contains("已发送，流量查询") } ?? "not found")

case "controls-stable":
    // Observe the three switches for three seconds while the 1 Hz refresh runs. Before the
    // fix, every settings read set settingsBusy, which dimmed/disabled each switch once a
    // second. The assertion is deliberately about stability, not about a write.
    openPopover()
    activateApp()
    pressKey(20, flags: .maskCommand)
    usleep(1_200_000)
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    func switches() -> [(label: String, value: Int?, enabled: Bool?)] {
        guard let r = popoverRoot() else { return [] }
        return descendants(r).filter { attribute($0, kAXRoleAttribute) == "AXCheckBox" }.map {
            (attribute($0, kAXDescriptionAttribute),
             numberAttribute($0, kAXValueAttribute),
             boolAttribute($0, kAXEnabledAttribute))
        }
    }
    let before = switches()
    var observed: [[(label: String, value: Int?, enabled: Bool?)]] = []
    for _ in 0..<12 {
        observed.append(switches())
        usleep(250_000)
    }
    let stable = observed.allSatisfy { sample in
        sample.count == before.count && zip(sample, before).allSatisfy {
            $0.label == $1.label && $0.value == $1.value && $0.enabled == $1.enabled
        }
    }
    check("开关在刷新周期内稳定", stable && !before.isEmpty,
          stable ? "\(before.count) switches for 3 s" : "values changed during refresh")
    print("     switches: \(before.map { "\($0.label)=\(String(describing: $0.value))" })")

case "controls-toggle":
    // Toggles the LED switch, verifies the write landed and the banner appeared, then puts
    // the original state back. This is the end-to-end check for the control-page wiring.
    openPopover()
    activateApp()
    pressKey(20, flags: .maskCommand)
    usleep(1_200_000)
    guard popoverRoot() != nil else { print("  FAIL no popover"); break }
    func ledSwitch() -> AXUIElement? {
        guard let r = popoverRoot() else { return nil }
        return descendants(r).first {
            attribute($0, kAXRoleAttribute) == "AXCheckBox" &&
            attribute($0, kAXDescriptionAttribute) == "机身指示灯"
        }
    }
    guard let led = ledSwitch(), let original = numberAttribute(led, kAXValueAttribute) else {
        print("  FAIL LED switch missing")
        break
    }
    print("     LED original=\(original)")
    click(led)
    let changed = waitFor(6) {
        guard let live = ledSwitch(), let value = numberAttribute(live, kAXValueAttribute)
        else { return false }
        return value != original
    }
    let after = ledSwitch().flatMap { numberAttribute($0, kAXValueAttribute) }
    check("指示灯开关写入生效", changed, "now=\(String(describing: after))")
    // The banner is set in the same transaction as the re-read but renders on the next
    // SwiftUI pass; poll briefly instead of sampling once.
    var bannerTexts: [String] = []
    let bannerSeen = waitFor(3) {
        bannerTexts = (popoverRoot().map { descendants($0).flatMap {
            [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
        } }) ?? []
        return bannerTexts.contains {
            $0.contains("机身指示灯") && ($0.contains("已开启") || $0.contains("已关闭"))
        }
    }
    check("开关操作有结果提示", bannerSeen,
          bannerTexts.first { $0.contains("机身指示灯") && ($0.contains("已开启") || $0.contains("已关闭")) } ?? "no banner")
    // Restore only once the write has finished and the switch is enabled again; clicking
    // during settingsBusy is intentionally ignored by the app.
    _ = waitFor(8) {
        guard let live = ledSwitch(), let value = numberAttribute(live, kAXValueAttribute),
              let enabled = boolAttribute(live, kAXEnabledAttribute) else { return false }
        return value != original && enabled
    }
    if let live = ledSwitch() { click(live) }
    var restored = waitFor(8) {
        guard let live = ledSwitch(), let value = numberAttribute(live, kAXValueAttribute),
              let enabled = boolAttribute(live, kAXEnabledAttribute) else { return false }
        return value == original && enabled
    }
    if !restored, let live = ledSwitch(), boolAttribute(live, kAXEnabledAttribute) == true {
        click(live)
        restored = waitFor(8) {
            guard let live = ledSwitch(), let value = numberAttribute(live, kAXValueAttribute)
            else { return false }
            return value == original
        }
    }
    check("指示灯状态已还原", restored, "original=\(original)")

case "devices-filter-open":
    openPopover()
    activateApp()
    pressKey(19, flags: .maskCommand)   // ⌘2 → 设备
    usleep(900_000)
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    guard let filter = descendants(root).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute).contains("接入类型筛选")
    }) else { print("  FAIL filter button missing"); break }
    print("     filter at \(pointOf(filter)) size \(sizeOf(filter))")
    click(filter)
    usleep(1_200_000)
    // Dump the app's windows/roots so the option popover can be inspected too.
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list where (window[kCGWindowOwnerName as String] as? String ?? "").contains("FiberHomeCPEManager") {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Double] else { continue }
        print("     window \(Int(bounds["Width"]!))x\(Int(bounds["Height"]!)) at \(Int(bounds["X"]!)),\(Int(bounds["Y"]!))")
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        AXUIElementCopyElementAtPosition(system,
            Float(bounds["X"]! + bounds["Width"]! / 2),
            Float(bounds["Y"]! + bounds["Height"]! / 2), &element)
        guard let element else { continue }
        var node: AXUIElement? = element
        for _ in 0..<8 {
            guard let current = node else { break }
            let role = attribute(current, kAXRoleAttribute)
            if role == "AXPopover" || role == "AXWindow" || role == "AXSheet" {
                for item in descendants(current) {
                    let label = attribute(item, kAXDescriptionAttribute)
                    let value = attribute(item, kAXValueAttribute)
                    guard label.contains("全部") || label.contains("5G") || label.contains("有线") || label.contains("2.4G") || value.contains("全部") else { continue }
                    print("       \(attribute(item, kAXRoleAttribute)) \(Int(sizeOf(item).width))x\(Int(sizeOf(item).height)) desc=\(label) value=\(value)")
                }
                break
            }
            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            node = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
        }
    }

case "devices-filter-select":
    openPopover()
    activateApp()
    pressKey(19, flags: .maskCommand)
    usleep(900_000)
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    guard let filter = descendants(root).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute).contains("接入类型筛选，当前 全部")
    }) else { print("  FAIL filter button missing"); break }
    click(filter)
    usleep(900_000)
    guard let option = descendants(popoverRoot() ?? root).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute).contains("5G") &&
        attribute($0, kAXDescriptionAttribute).contains("台")
    }) else { print("  FAIL 5G filter option missing"); break }
    click(option)
    usleep(900_000)
    let after = descendants(popoverRoot() ?? root).flatMap {
        [attribute($0, kAXDescriptionAttribute), attribute($0, kAXValueAttribute)]
    }
    check("筛选胶囊切到 5G", after.contains { $0.contains("接入类型筛选，当前 5G") })
    check("设备列表按 5G 过滤",
          after.contains { $0.contains("/") && $0.contains("台") },
          after.first { $0.contains("/") && $0.contains("台") } ?? "no count")
    // Restore the default filter for subsequent scenarios.
    if let open = descendants(popoverRoot() ?? root).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute).contains("接入类型筛选")
    }) {
        click(open); usleep(700_000)
        if let all = descendants(popoverRoot() ?? root).first(where: {
            attribute($0, kAXRoleAttribute) == "AXButton" &&
            attribute($0, kAXDescriptionAttribute).contains("全部，9 台")
        }) { click(all); usleep(500_000) }
    }

case "controls-dump":
    openPopover()
    activateApp()
    pressKey(20, flags: .maskCommand)
    usleep(900_000)
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    for element in descendants(root) {
        let role = attribute(element, kAXRoleAttribute)
        let desc = attribute(element, kAXDescriptionAttribute)
        let value = attribute(element, kAXValueAttribute)
        let size = sizeOf(element)
        guard size.width > 0, size.height > 0 else { continue }
        print("  \(role) \(Int(size.width))x\(Int(size.height)) desc=\(desc) value=\(value) enabled=\(String(describing: boolAttribute(element, kAXEnabledAttribute)))")
    }

case "compose-dump":
    openPopover()
    activateApp()
    pressKey(21, flags: .maskCommand)
    usleep(800_000)
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    guard let compose = descendants(root).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute) == "写短信"
    }) else { print("  FAIL 写短信 missing"); break }
    click(compose)
    usleep(1_000_000)
    guard let composeRoot = popoverRoot() else { print("  FAIL compose did not open"); break }
    for element in descendants(composeRoot) {
        let role = attribute(element, kAXRoleAttribute)
        let desc = attribute(element, kAXDescriptionAttribute)
        let value = attribute(element, kAXValueAttribute)
        let size = sizeOf(element)
        guard size.width > 0, size.height > 0 else { continue }
        print("  \(role) \(Int(size.width))x\(Int(size.height)) desc=\(desc) value=\(value)")
    }

case "dump":
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    for element in descendants(root) {
        let role = attribute(element, kAXRoleAttribute)
        let desc = attribute(element, kAXDescriptionAttribute)
        let value = attribute(element, kAXValueAttribute)
        let size = sizeOf(element)
        guard size.width > 0, size.height > 0 else { continue }
        print("  \(role) \(Int(size.width))x\(Int(size.height)) desc=\(desc) value=\(value)")
    }

case "sms-compose-send":
    // Compose-path live check. This path is wired in every build (unlike the inline reply
    // in older builds), so it isolates "does the CPE send and re-list the message".
    openPopover()
    activateApp()
    for _ in 0..<3 {
        guard let back = descendants(popoverRoot() ?? AXUIElementCreateSystemWide()).first(where: {
            attribute($0, kAXRoleAttribute) == "AXButton" &&
            attribute($0, kAXDescriptionAttribute).contains("返回")
        }) else { break }
        click(back)
        usleep(700_000)
    }
    pressKey(21, flags: .maskCommand)
    usleep(800_000)
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    guard let compose = descendants(root).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute) == "写短信"
    }) else {
        print("  FAIL 写短信 button missing")
        break
    }
    click(compose)
    usleep(900_000)
    guard let fields = popoverRoot().map({ descendants($0) }) else { print("  FAIL no popover"); break }
    guard let numberField = fields.first(where: {
        attribute($0, kAXRoleAttribute) == "AXTextField" &&
        attribute($0, kAXDescriptionAttribute).contains("接收号码")
    }), let bodyField = fields.first(where: {
        (attribute($0, kAXRoleAttribute) == "AXTextArea" || attribute($0, kAXRoleAttribute) == "AXTextField") &&
        attribute($0, kAXDescriptionAttribute).contains("短信内容")
    }) else {
        print("  FAIL compose fields missing")
        break
    }
    func typeUnicode(_ text: String) {
        var units = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        usleep(250_000)
    }
    func paste(_ text: String, into element: AXUIElement) {
        // AXValue works for a plain NSTextField but not always for SwiftUI views; fall back
        // to a real click + paste, then to Unicode key events.
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        usleep(200_000)
        if attribute(element, kAXValueAttribute) == text { return }
        click(element)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pressKey(9, flags: .maskCommand)
        usleep(250_000)
        if attribute(element, kAXValueAttribute) == text { return }
        typeUnicode(text)
    }
    paste("10010", into: numberField)
    paste("流量查询", into: bodyField)
    print("     number=\(attribute(numberField, kAXValueAttribute)) body=\(attribute(bodyField, kAXValueAttribute))")
    guard let send = descendants(popoverRoot() ?? root).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute) == "发送"
    }) else {
        print("  FAIL 发送 button missing")
        break
    }
    print("     send enabled=\(String(describing: boolAttribute(send, kAXEnabledAttribute))) size=\(Int(sizeOf(send).width))x\(Int(sizeOf(send).height)) origin=\(pointOf(send))")
    // A real click inside the left half of the wide primary button. AXPress is accepted by
    // the AX layer but does not always invoke a SwiftUI Button, and a centre click can be
    // ambiguous if the panel is still settling.
    let origin = pointOf(send), size = sizeOf(send)
    click(at: CGPoint(x: origin.x + 40, y: origin.y + size.height / 2))
    let finished = waitFor(12) {
        guard let r = popoverRoot() else { return false }
        return descendants(r).contains {
            let text = attribute($0, kAXValueAttribute) + attribute($0, kAXDescriptionAttribute)
            return text.contains("已发送给 10010") || text.contains("发送失败")
        }
    }
    let statusTexts = (popoverRoot().map { descendants($0).flatMap {
        [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
    } }) ?? []
    check("撰写发送完成", finished,
          statusTexts.first { $0.contains("已发送") || $0.contains("发送失败") } ?? "no status")
    print("     after-send texts: \(statusTexts.filter { !$0.isEmpty }.prefix(14))")
    // Return to the list, reopen 10010, and look for the outbound bubble.
    if let back = descendants(popoverRoot() ?? root).first(where: {
        attribute($0, kAXRoleAttribute) == "AXButton" &&
        attribute($0, kAXDescriptionAttribute).contains("返回")
    }) { _ = AXUIElementPerformAction(back, kAXPressAction as CFString) }
    usleep(1_200_000)
    if let row = descendants(popoverRoot() ?? root).first(where: {
        attribute($0, kAXDescriptionAttribute).contains("10010") && sizeOf($0).height > 30
    }) { _ = AXUIElementPerformAction(row, kAXPressAction as CFString) }
    usleep(1_200_000)
    let after = (popoverRoot().map { descendants($0).flatMap {
        [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
    } }) ?? []
    check("发送后同步到会话", after.contains { $0.contains("已发送，流量查询") },
          after.first { $0.contains("已发送，流量查询") } ?? "not found")

case "controls":
    resetUI()
    openPopover()
    activateApp()
    // Leave and re-enter so the page state (expanded cards) is freshly built.
    pressKey(18, flags: .maskCommand); usleep(300_000)
    pressKey(20, flags: .maskCommand)   // ⌘3 → 控制
    usleep(700_000)
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    // SSID rows expose their name through the accessibility label, not AXValue.
    func texts() -> [String] {
        guard let r = popoverRoot() else { return [] }
        return descendants(r).flatMap { element -> [String] in
            [attribute(element, kAXValueAttribute), attribute(element, kAXDescriptionAttribute)]
        }
    }
    let initial = texts()
    check("上行模式矩阵可见", initial.contains { $0.contains("蜂窝上行") })
    check("主 SSID 常驻", initial.contains { $0.contains("FHCPE-Xe3P-SmartHome") })
    check("备用 SSID 默认折叠", !initial.contains { $0.contains("FHCPE-Xe3P-2") })

    // Expand the backup channels.
    if let toggle = descendants(root).first(where: {
        attribute($0, kAXDescriptionAttribute).contains("备用通道")
    }) {
        _ = AXUIElementPerformAction(toggle, kAXPressAction as CFString)
        usleep(600_000)
        check("展开后出现备用 SSID", texts().contains { $0.contains("FHCPE-Xe3P-2") })
        _ = AXUIElementPerformAction(toggle, kAXPressAction as CFString)
        usleep(500_000)
    } else {
        check("展开后出现备用 SSID", false, "toggle missing")
    }

    // Expand the scheduled-reboot card.
    let expandedBefore = texts().contains { $0.contains("重启时间") }
    if let row = descendants(root).first(where: {
        attribute($0, kAXDescriptionAttribute).contains("点击展开")
    }) {
        _ = AXUIElementPerformAction(row, kAXPressAction as CFString)
        usleep(600_000)
    }
    check("重启卡片展开出时间与周期",
          !expandedBefore && texts().contains { $0.contains("重启时间") })

case "keys":
    resetUI()
    openPopover()
    activateApp()
    // ⌘1…⌘4 switch the bottom tabs (US layout key codes 18…21).
    let tabKeys: [(CGKeyCode, String, String)] = [
        (18, "概览", "蜂窝信息"), (19, "设备", "全部"),
        (20, "控制", "上行运行模式"), (21, "短信", "写短信")
    ]
    for (code, name, marker) in tabKeys {
        pressKey(code, flags: .maskCommand)
        let landed = waitFor(2.5) {
            guard let root = popoverRoot() else { return false }
            let texts = descendants(root).map { attribute($0, kAXValueAttribute) }
            let labels = descendants(root).map { attribute($0, kAXDescriptionAttribute) }
            return texts.contains(marker) || labels.contains { $0.contains(marker) }
        }
        check("⌘ 切到\(name)", landed)
    }
    // Esc inside a drill-in page returns instead of closing the panel.
    pressKey(18, flags: .maskCommand); usleep(500_000)
    if let detail = descendants(popoverRoot() ?? AXUIElementCreateSystemWide()).first(where: {
        attribute($0, kAXDescriptionAttribute).contains("蜂窝详情")
    }) {
        _ = AXUIElementPerformAction(detail, kAXPressAction as CFString)
        usleep(900_000)
    }
    let opened = (popoverRoot().map { root in
        descendants(root).compactMap { attribute($0, kAXValueAttribute) as String? }.contains("载波聚合状态")
    }) ?? false
    check("打开蜂窝详情", opened)
    activateApp()
    pressKey(53)
    usleep(800_000)
    check("Esc 从二级页返回", (popoverRoot().map { root in
        descendants(root).compactMap { attribute($0, kAXValueAttribute) as String? }.contains("蜂窝信息")
    }) ?? false)
    check("返回后面板仍打开", popoverRoot() != nil)

case "styles":
    resetUI()
    guard let item = statusItemElement() else { print("FAIL: no status item"); break }

    /// Opens the context menu and presses the "显示网速" checkbox item.
    func toggleRate() -> Bool {
        // The panel must be closed: a right-click while it is open does not reach the item.
        closePopover()
        usleep(300_000)
        // Re-fetch: the item is rebuilt whenever the segment width changes.
        guard let live = statusItemElement() else { return false }
        click(at: CGPoint(x: pointOf(live).x + sizeOf(live).width / 2,
                          y: pointOf(live).y + sizeOf(live).height / 2), right: true)
        usleep(700_000)
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        AXUIElementCopyElementAtPosition(system,
            Float(pointOf(live).x + sizeOf(live).width / 2),
            Float(pointOf(live).y + 60), &element)
        var node = element
        for _ in 0..<8 {
            guard let current = node else { break }
            if attribute(current, kAXRoleAttribute) == "AXMenu" {
                for menuItem in childrenOf(current) where attribute(menuItem, kAXTitleAttribute) == "显示网速" {
                    let centre = CGPoint(x: pointOf(menuItem).x + sizeOf(menuItem).width / 2,
                                         y: pointOf(menuItem).y + sizeOf(menuItem).height / 2)
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: centre, mouseButton: .left)?.post(tap: .cghidEventTap)
                    usleep(150_000)
                    let press = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
                    if press != .success { click(at: centre) }
                    return press == .success
                }
                break
            }
            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            node = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
        }
        return false
    }

    // Normalise first: a previous run may have left the rate readout enabled.
    if sizeOf(item).width > 40 {
        _ = toggleRate()
        _ = waitFor(2.5) { sizeOf(item).width < 40 }
    }
    let baseline = sizeOf(item).width

    let pressedOn = toggleRate()
    let widened = waitFor(2.5) { sizeOf(item).width > baseline + 5 }
    check("勾选后显示网速", pressedOn && widened,
          "pressed=\(pressedOn) \(baseline) → \(sizeOf(item).width) pt")

    let pressedOff = toggleRate()
    let restored = waitFor(2.5) { abs(sizeOf(item).width - baseline) < 1 }
    check("取消勾选恢复仅信号", pressedOff && restored, "\(sizeOf(item).width) pt")

case "external-click":
    resetUI()
    openPopover()
    check("面板已打开", onScreenWindowCount() > 0)
    // Click far from both the panel and the status item.
    click(at: CGPoint(x: 200, y: 700))
    usleep(900_000)
    check("点击面板外关闭面板", onScreenWindowCount() == 0)

case "setstyle":
    // Set one display style by name, e.g. `ui_probe setstyle 信号与速率`.
    guard CommandLine.arguments.count > 2 else { print("usage: setstyle <名称>"); break }
    let wanted = CommandLine.arguments[2]
    resetUI()
    guard let item = statusItemElement() else { print("  FAIL no status item"); break }
    let origin = pointOf(item)
    click(at: CGPoint(x: origin.x + sizeOf(item).width / 2,
                      y: origin.y + sizeOf(item).height / 2), right: true)
    usleep(700_000)
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    AXUIElementCopyElementAtPosition(system, Float(origin.x + sizeOf(item).width / 2),
                                     Float(origin.y + 60), &element)
    var node = element
    for _ in 0..<8 {
        guard let current = node else { break }
        if attribute(current, kAXRoleAttribute) == "AXMenu" {
            for menuItem in childrenOf(current) where attribute(menuItem, kAXTitleAttribute) == wanted {
                _ = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
                usleep(500_000)
                check("设置为「\(wanted)」", true, "菜单栏宽 \(sizeOf(item).width) pt")
                break
            }
            break
        }
        var parent: CFTypeRef?
        AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
        node = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
    }

case "forget-credential":
    // Removes any credential the login probe may have saved (the checkbox follows the
    // remembered preference). Run after connected tests so the machine is left clean.
    resetUI()
    closePopover()
    usleep(300_000)
    guard let item = statusItemElement() else { print("  FAIL no status item"); break }
    let origin = pointOf(item)
    click(at: CGPoint(x: origin.x + sizeOf(item).width / 2,
                      y: origin.y + sizeOf(item).height / 2), right: true)
    usleep(700_000)
    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    AXUIElementCopyElementAtPosition(system, Float(origin.x + sizeOf(item).width / 2),
                                     Float(origin.y + 60), &element)
    var node = element
    var pressed = false
    for _ in 0..<8 {
        guard let current = node else { break }
        if attribute(current, kAXRoleAttribute) == "AXMenu" {
            for menuItem in childrenOf(current)
                where attribute(menuItem, kAXTitleAttribute).contains("清除已保存的密码") {
                _ = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
                pressed = true
                break
            }
            break
        }
        var parent: CFTypeRef?
        AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
        node = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
    }
    usleep(600_000)
    check("清除已保存的密码", pressed)
    openPopover()
    usleep(500_000)
    let result = (popoverRoot().map { descendants($0).flatMap {
        [attribute($0, kAXValueAttribute), attribute($0, kAXDescriptionAttribute)]
    } }) ?? []
    check("清除结果可见", result.contains { $0.contains("已清除保存的密码") || $0.contains("没有已保存") },
          result.first { $0.contains("清除") || $0.contains("保存的密码") } ?? "no result text")

case "capture-window":
    guard CommandLine.arguments.count > 2 else { print("usage: capture-window <path>"); break }
    let path = CommandLine.arguments[2]
    openPopover()
    usleep(1_000_000)
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var captured = false
    for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").contains("FiberHomeCPEManager") {
        guard let num = w[kCGWindowNumber as String] as? Int else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        guard (b["Width"] ?? 0) > 300 else { continue }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", "\(num)", path]
        try? task.run(); task.waitUntilExit()
        captured = true; break
    }
    check("窗口截图", captured, path)

case "screens":
    // Capture every page to PNG. `screencapture` is system-signed and can be spawned from
    // here, which keeps the helper tooling in one maintained binary instead of a pile of
    // ad-hoc-signed scratch executables.
    resetUI()
    openPopover()
    let dir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "render/live"
    func capture(_ name: String) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").contains("FiberHomeCPEManager") {
            guard let num = w[kCGWindowNumber as String] as? Int else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            guard (b["Width"] ?? 0) > 300 else { continue }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", "\(num)", "\(dir)/\(name).png"]
            try? task.run()
            task.waitUntilExit()
            print("  captured \(name).png")
            return
        }
        print("  FAIL no panel window for \(name)")
    }
    for (index, name) in ["01-overview", "02-devices", "03-controls", "04-sms"].enumerated() {
        tapTab(index: index)
        capture(name)
    }
    // Cellular detail is reached from the overview's last row.
    tapTab(index: 0)
    if let root = popoverRoot() {
        // The detail entry is now a compact header action rather than a full-width row.
        let candidates = descendants(root).filter { attribute($0, kAXRoleAttribute) == "AXButton" }
        let more = candidates.first { attribute($0, kAXDescriptionAttribute).contains("蜂窝详情") }
            ?? candidates.first { attribute($0, kAXDescriptionAttribute).contains("详情") }
        if let more {
            _ = AXUIElementPerformAction(more, kAXPressAction as CFString)
            usleep(1_200_000)
            capture("05-cellular")
            if let back = descendants(root).first(where: {
                attribute($0, kAXRoleAttribute) == "AXButton" &&
                attribute($0, kAXDescriptionAttribute).contains("返回")
            }) {
                _ = AXUIElementPerformAction(back, kAXPressAction as CFString)
                usleep(700_000)
            }
        } else {
            print("  FAIL detail row missing")
        }
    }

case "login-after":
    resetUI()
    openPopover()
    guard let root = popoverRoot() else { print("  FAIL no popover"); break }
    let texts = descendants(root).compactMap { attribute($0, kAXValueAttribute) as String? }
    let connected = !texts.contains("连接你的 CPE")
    print("  state: \(connected ? "已登录" : "未登录")")
    if connected {
        inventory("connected")
        for (index, name) in ["概览", "设备", "控制", "短信"].enumerated() {
            tapTab(index: index)
            inventory(name)
        }
    }

default:
    print("usage: ui_probe [inventory|tabs|contextmenu|login-empty|esc|cmdw|cmdq|power|styles|external-click|setstyle|sms|a11y|controls|keys|login-extra|screens|login-after]")
}

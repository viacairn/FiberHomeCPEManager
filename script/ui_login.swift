import Cocoa
import ApplicationServices

// Drives the real app UI: opens the panel, types the password into the secure field, and
// presses the connect button. The password comes from the environment and is never printed.
func str(_ e: AXUIElement, _ k: String) -> String { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return (v as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v); return (v as? [AXUIElement]) ?? [] }
func pt(_ e: AXUIElement) -> CGPoint { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &v); var p = CGPoint.zero; if let v, CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgPoint, &p) }; return p }
func sz(_ e: AXUIElement) -> CGSize { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &v); var s = CGSize.zero; if let v, CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &s) }; return s }
func click(_ e: AXUIElement) {
    let p = pt(e), s = sz(e)
    let c = CGPoint(x: p.x + s.width/2, y: p.y + s.height/2)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(70_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func typeTextLegacy(_ text: String) {
    for ch in text {
        var unit = UniChar(String(ch).utf16.first!)
        let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let u = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        d?.flags = []
        u?.flags = []
        d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        u?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        d?.post(tap: .cghidEventTap); usleep(30_000)
        u?.post(tap: .cghidEventTap); usleep(30_000)
    }
}
func popoverRoot() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").contains("FiberHomeCPEManager") {
        guard let b = w[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) > 300 else { continue }
        var el: AXUIElement?
        AXUIElementCopyElementAtPosition(system, Float(b["X"]! + b["Width"]!/2), Float(b["Y"]! + b["Height"]!/2), &el)
        var node = el
        for _ in 0..<6 {
            guard let n = node else { return nil }
            if str(n, kAXRoleAttribute) == "AXPopover" { return n }
            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(n, kAXParentAttribute as CFString, &parent)
            node = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
        }
    }
    return nil
}
/// Fresh walk of the popover tree. SwiftUI re-renders on every keystroke, so element
/// references captured before typing become stale and report a zero size.
func elements() -> [AXUIElement] {
    guard let root = popoverRoot() else { return [] }
    var out: [AXUIElement] = []
    func walk(_ e: AXUIElement) { out.append(e); for c in kids(e) { walk(c) } }
    walk(root)
    return out
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "local.fhcpem.app" && !$0.isTerminated
}) else { print("app not running"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
var ex: CFTypeRef?; AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &ex)
let bar = unsafeBitCast(ex!, to: AXUIElement.self)
guard let item = kids(bar).first else { print("no status item"); exit(1) }
if popoverRoot() == nil {
    _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
    usleep(900_000)
}
app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
for _ in 0..<10 where !app.isActive { usleep(100_000) }

func step(_ name: String) {
    print("STEP \(name) terminated=\(app.isTerminated) popover=\(popoverRoot() != nil)"); fflush(stdout)
    if app.isTerminated { exit(2) }
}

let fields = elements().filter { str($0, kAXRoleAttribute) == "AXTextField" }
guard fields.count >= 3 else { print("fields missing: \(fields.count)"); exit(1) }
step("fields")

func typeText(_ text: String) {
    for scalar in text.unicodeScalars {
        var unit = UniChar(scalar.value)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        down?.post(tap: .cghidEventTap)
        usleep(8_000)
        up?.post(tap: .cghidEventTap)
        usleep(8_000)
    }
}

/// A fresh instance always starts at 192.168.8.1; only correct it when something else is
/// there (a previous scenario pressing 导入网关, for example).
let host = ProcessInfo.processInfo.environment["CPE_HOST"] ?? "192.168.8.1"
let password = ProcessInfo.processInfo.environment["CPE_PASS"] ?? ""
if str(fields[0], kAXValueAttribute) != host {
    click(fields[0])
    usleep(200_000)
    typeText(host)
    usleep(200_000)
    print("address now:", str(fields[0], kAXValueAttribute))
}

// The secure field rejects AX value assignment, so real keystrokes are required.
click(fields[2])
step("clicked-password")
usleep(350_000)
// Paste rather than keystroke every character. A synthetic Unicode "Q" with a stale
// Command modifier is interpreted as ⌘Q and quits the app; paste has no key equivalent.
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(password, forType: .string)
// Never leave the password on the shared pasteboard after the probe exits.
defer { NSPasteboard.general.clearContents() }
func pasteKey() {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    usleep(40_000)
    up?.post(tap: .cghidEventTap)
}
pasteKey()
step("typed-password")
usleep(300_000)

let buttonLabels = elements().filter { str($0, kAXRoleAttribute) == "AXButton" }.map { "\(str($0, kAXDescriptionAttribute))#\(Int(sz($0).width))" }
guard let button = elements().first(where: {
    str($0, kAXRoleAttribute) == "AXButton" &&
    str($0, kAXDescriptionAttribute) == "连接" && sz($0).width > 200
}) else {
    print("connect missing (labels: \(buttonLabels))")
    exit(1)
}
_ = AXUIElementPerformAction(button, kAXPressAction as CFString)

func formTexts() -> [String] {
    elements().compactMap { str($0, kAXValueAttribute) as? String }.filter { !$0.isEmpty }
}
var texts = formTexts()
let deadline = Date().addingTimeInterval(20)
while Date() < deadline {
    let t = formTexts()
    if !t.contains("FiberHome CPE Manager") { texts = t; break }
    if t.contains(where: { $0.contains("用户名或密码错误") || $0.contains("Could not connect") || $0.contains("请求失败") }) {
        texts = t; break
    }
    usleep(150_000)
    texts = t
}

let connected = !texts.contains("FiberHome CPE Manager") && !texts.contains("请输入密码后再连接")
print(connected ? "LOGIN OK" : "LOGIN FAILED")
print("page texts:", texts.prefix(10))

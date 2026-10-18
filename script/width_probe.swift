import Cocoa
import ApplicationServices

/// Width probes used by `verify-width.sh`.
///
/// `menubar <n> <interval>` samples the menu-bar item width n times and fails if it ever
/// changes. `window <n> <interval>` does the same for the popover window and also asserts
/// it sits at the design's 350x580.

func string(_ element: AXUIElement, _ key: String) -> String {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return (value as? String) ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    return (value as? [AXUIElement]) ?? []
}

func size(_ element: AXUIElement) -> CGSize {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
    var result = CGSize.zero
    if let value, CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(value as! AXValue, .cgSize, &result)
    }
    return result
}

func appElement() -> AXUIElement? {
    guard let app = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == "local.fhcpem.app" }) else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}

func menuBarItemWidths() -> [CGFloat] {
    guard let ax = appElement() else { return [] }
    var extras: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &extras)
    guard let raw = extras, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return [] }
    let bar = unsafeBitCast(raw, to: AXUIElement.self)
    return children(bar).map { size($0).width }
}

func windowSizes() -> [CGSize] {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { window in
        guard (window[kCGWindowOwnerName as String] as? String ?? "").contains("FiberHomeCPEManager"),
              let bounds = window[kCGWindowBounds as String] as? [String: Double],
              let width = bounds["Width"], let height = bounds["Height"] else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// Clicks the app's menu-bar item so the popover appears.
func openPopover() {
    guard let ax = appElement() else { return }
    var extras: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &extras)
    guard let raw = extras, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
    let bar = unsafeBitCast(raw, to: AXUIElement.self)
    for item in children(bar) {
        var position: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position)
        var origin = CGPoint.zero
        if let position, CFGetTypeID(position) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        let itemSize = size(item)
        let center = CGPoint(x: origin.x + itemSize.width / 2, y: origin.y + itemSize.height / 2)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(80_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}

func sample(_ label: String, count: Int, interval: Double, read: () -> [CGFloat]) -> Int32 {
    var seen = Set<CGFloat>()
    var samples: [CGFloat] = []
    for _ in 0..<count {
        let values = read()
        if let first = values.first {
            seen.insert(first)
            samples.append(first)
        }
        Thread.sleep(forTimeInterval: interval)
    }
    let unique = seen.sorted()
    if samples.isEmpty {
        print("\(label): no item found")
        return 1
    }
    let range = (samples.min() ?? 0)...(samples.max() ?? 0)
    print("\(label): \(samples.count) samples, widths \(unique.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
    if unique.count == 1 {
        print("\(label): PASS (width stable at \(String(format: "%.1f", unique[0])) pt)")
        return 0
    }
    print("\(label): FAIL (width varies by \(String(format: "%.1f", range.upperBound - range.lowerBound)) pt)")
    return 1
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "menubar"
let count = args.count > 2 ? Int(args[2]) ?? 20 : 20
let interval = args.count > 3 ? Double(args[3]) ?? 1 : 1

switch mode {
case "menubar":
    exit(sample("menu bar", count: count, interval: interval) { menuBarItemWidths() })
case "window":
    // The popover only exists while it is open; open it through its menu-bar item first.
    if windowSizes().isEmpty {
        openPopover()
        Thread.sleep(forTimeInterval: 1.5)
    }
    var observed: [String] = []
    for _ in 0..<count {
        for size in windowSizes() {
            let text = String(format: "%.0fx%.0f", size.width, size.height)
            if !observed.contains(text) { observed.append(text) }
        }
        Thread.sleep(forTimeInterval: interval)
    }
    print("window: observed sizes \(observed.joined(separator: ", "))")
    guard !observed.isEmpty else {
        print("window: FAIL (no popover window found; open the menu-bar item first)")
        exit(1)
    }
    let unexpected = observed.filter { $0 != "350x580" }
    if unexpected.isEmpty {
        print("window: PASS (popover stays 350x580)")
        exit(0)
    }
    print("window: FAIL (unexpected popover size: \(unexpected.joined(separator: ", ")))")
    exit(1)
default:
    print("usage: width_probe [menubar|window] [count] [interval]")
    exit(2)
}

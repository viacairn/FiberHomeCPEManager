import AppKit
import SwiftUI
import FHCPECore
import FHCPEMUI

/// Development-only renderer. It mounts the real SwiftUI shells offscreen and writes PNGs
/// so layout can be inspected without Screen Recording permission and without touching a
/// live device session. Not part of the shipped app bundle.
@main
struct UIRender {
    @MainActor private static var previewWindow: NSWindow?
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--always-scrollbars") {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleShowScrollBars"] = "Always"
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if args.contains("--interactive-preview") || ProcessInfo.processInfo.environment["FHCPEM_INTERACTIVE_PREVIEW"] == "1" {
            app.setActivationPolicy(.regular)
            let model = Fixtures().connected(tab: 0)
            let controller = PopoverHostingController(rootView: ShellView(model: model),
                                                     designSize: NSSize(width: Theme.compactWidth, height: Theme.compactHeight))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.compactWidth, height: Theme.compactHeight),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "FiberHome CPE Manager · 模拟数据预览"
            window.contentViewController = controller
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window
            app.activate(ignoringOtherApps: true)
            app.run()
            return
        }
        if args.contains("--controls-performance-audit") {
            auditControlsPerformance()
            return
        }
        if args.contains("--chrome-audit") {
            auditPopover()
            return
        }
        let outDir = args.count > 1 ? args[1] : "./render"
        let dark = args.contains("--dark")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let pages = args.first { $0.hasPrefix("--pages=") }
            .map { Set($0.dropFirst("--pages=".count).split(separator: ",").map(String.init)) }
        let renderer = Renderer(outputDirectory: outDir, dark: dark, pages: pages)
        renderer.renderAll()
        print("wrote \(renderer.written.count) images to \(outDir)")
        for path in renderer.written { print(path) }
        let report = (outDir as NSString).appendingPathComponent("layout.json")
        if let data = try? JSONSerialization.data(withJSONObject: renderer.layoutMetrics, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: report))
        }
        if !renderer.horizontalOverflow.isEmpty {
            for issue in renderer.horizontalOverflow { print("LAYOUT FAIL: \(issue)") }
            exit(2)
        }
    }

    @MainActor private static func auditControlsPerformance() {
        let model = Fixtures().connected(tab: 0)
        let controller = PopoverHostingController(rootView: ShellView(model: model),
                                                 designSize: NSSize(width: Theme.compactWidth, height: Theme.compactHeight))
        let host = controller.view
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.contentViewController = controller
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        for (index, tab) in [2, 0, 2, 0, 2].enumerated() {
            let start = ProcessInfo.processInfo.systemUptime
            model.tab = tab
            host.layoutSubtreeIfNeeded()
            let layoutMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            print("tab=\(tab), pass=\(index + 1), layout-ms=\(String(format: "%.2f", layoutMS)), layout-and-draw-ms=\(String(format: "%.2f", ms))")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        window.contentView = nil
    }

    @MainActor private static func auditPopover() {
        let fixtures = Fixtures()
        var scenes = (0...3).map { ("tab-\($0)", fixtures.connected(tab: $0)) }
        for (name, route) in [("cellular", ShellView.Route.cellular), ("about", .about),
                              ("ddns", .ddns), ("ports", .portMapping)] {
            let model = fixtures.connected(tab: 0); model.route = route
            scenes.append((name, model))
        }
        for name in ["sms-long", "sms-late-data", "sms-error", "sms-long-number"] {
            let model = fixtures.connected(tab: 3)
            model.threads = name == "sms-late-data" ? [] : fixtures.longThreads()
            model.smsRoute = .thread; model.selectedThreadID = "10010"
            if name == "sms-long-number" {
                let thread = fixtures.longNumberThread()
                model.threads = [thread]; model.selectedThreadID = thread.id
            }
            if name == "sms-error" { model.notices.show("短信读取失败：请求超时", tone: .error) }
            scenes.append((name, model))
        }
        for tab in [1, 2, 3] {
            let model = fixtures.connected(tab: tab); model.data.connected = false
            scenes.append(("offline-\(tab)", model))
        }
        scenes.append(("connect", fixtures.firstRun()))
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        let anchor = NSWindow(contentRect: NSRect(x: visible.midX, y: visible.maxY - 30, width: 40, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let positioning = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        anchor.contentView = positioning; anchor.orderFrontRegardless()
        var failures: [String] = []
        var records: [[String: Any]] = []
        let size = NSSize(width: Theme.compactWidth, height: Theme.compactHeight)
        let dark = CommandLine.arguments.contains("--dark")
        let nativeGlass = !CommandLine.arguments.contains("--fallback-material")
        let auditHeaderColor = CommandLine.arguments.contains("--header-audit")
        let imageDirectory = CommandLine.arguments.first { $0.hasPrefix("--audit-images=") }
            .map { String($0.dropFirst("--audit-images=".count)) }
        if let imageDirectory {
            try? FileManager.default.createDirectory(atPath: imageDirectory, withIntermediateDirectories: true)
        }
        print("preferred scroller style", NSScroller.preferredScrollerStyle.rawValue)
        for (name, model) in scenes {
            let popover = NSPopover()
            popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var surfaceFrame = CGRect.zero
            let controller = PopoverHostingController(rootView: ShellView(model: model)
                .environment(\.fhcpemGlassEnabled, nativeGlass)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { surfaceFrame = $0 },
                designSize: size)
            popover.behavior = .applicationDefined; popover.animates = false
            popover.contentViewController = controller; popover.contentSize = size
            popover.hasFullSizeContent = true
            popover.show(relativeTo: positioning.bounds, of: positioning, preferredEdge: .minY)
            for (phase, delay) in [("first", 0.02), ("settled", 0.2)] {
                if name == "sms-late-data", phase == "settled" { model.threads = fixtures.longThreads() }
                RunLoop.main.run(until: Date().addingTimeInterval(delay))
                controller.view.layoutSubtreeIfNeeded()
                guard let window = controller.view.window else { failures.append("\(name) missing window"); continue }
                let insets = controller.view.safeAreaInsets
                let expectedWindowSize = NSSize(width: size.width + insets.left + insets.right,
                                                height: size.height + insets.top + insets.bottom)
                if abs(window.frame.width - expectedWindowSize.width) > 0.5 ||
                    abs(window.frame.height - expectedWindowSize.height) > 0.5 {
                    failures.append("\(name) \(phase) background extension changed: \(window.frame.size), expected \(expectedWindowSize)")
                }
                if abs(popover.contentSize.width - size.width) > 0.5 ||
                    abs(popover.contentSize.height - size.height) > 0.5 {
                    failures.append("\(name) \(phase) content size changed: \(popover.contentSize)")
                }
                let bounds = controller.view.bounds
                if abs(surfaceFrame.minX - bounds.minX) > 0.5 || abs(surfaceFrame.minY - bounds.minY) > 0.5 ||
                    abs(surfaceFrame.width - bounds.width) > 0.5 || abs(surfaceFrame.height - bounds.height) > 0.5 {
                    failures.append("\(name) \(phase) background does not fill window: \(surfaceFrame), hosting bounds \(bounds)")
                }
                var scrollCount = 0
                func inspect(_ view: NSView) {
                    if let scroll = view as? NSScrollView, let document = scroll.documentView {
                        scrollCount += 1
                        let overflow = document.frame.width - scroll.contentSize.width
                        let gutter = scroll.bounds.width - scroll.contentSize.width
                        let origin = scroll.contentView.bounds.minX
                        let viewportFrame = scroll.convert(scroll.bounds, to: controller.view)
                        let phoneOverflow = isPhoneOverflow(scroll, page: name)
                        if abs(viewportFrame.midX - bounds.midX) > 0.5 {
                            failures.append("\(name) \(phase) page content not centered: \(viewportFrame)")
                        }
                        if gutter > 0.5 || (!phoneOverflow && (overflow > 0.5 || abs(origin) > 0.5 ||
                            scroll.horizontalScrollElasticity != .none || scroll.hasHorizontalScroller)) {
                            failures.append("\(name) \(phase) horizontal scroll/space: \(overflow), \(origin), \(gutter)")
                        }
                        if phoneOverflow, phase == "settled" {
                            if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                     wheelCount: 2, wheel1: 0, wheel2: -80, wheel3: 0),
                               let event = NSEvent(cgEvent: cgEvent) {
                                scroll.scrollWheel(with: event)
                                if scroll.contentView.bounds.minX <= origin + 0.5 {
                                    failures.append("\(name) horizontal wheel cannot reveal the rest of the number")
                                }
                                scroll.contentView.scroll(to: NSPoint(x: origin, y: scroll.contentView.bounds.minY))
                                scroll.reflectScrolledClipView(scroll.contentView)
                            } else { failures.append("\(name) cannot create in-process horizontal wheel event") }
                        }
                        records.append(["page": name, "phase": phase, "window": NSStringFromSize(window.frame.size),
                                        "designSize": NSStringFromSize(size),
                                        "surfaceFrame": NSStringFromRect(surfaceFrame),
                                        "viewportFrame": NSStringFromRect(viewportFrame),
                                        "nativeInsets": ["top": insets.top, "bottom": insets.bottom,
                                                         "left": insets.left, "right": insets.right],
                                        "viewportWidth": scroll.contentSize.width, "documentWidth": document.frame.width,
                                        "horizontalOverflow": overflow, "horizontalOrigin": origin,
                                        "intentionalPhoneScrolling": phoneOverflow,
                                        "reservedScrollerWidth": gutter,
                                        "topInset": scroll.contentInsets.top, "bottomInset": scroll.contentInsets.bottom])
                    }
                    view.subviews.forEach(inspect)
                }
                inspect(controller.view)
                if name == "tab-2", phase == "settled", CommandLine.arguments.contains("--header-scroll-audit") {
                    auditScrolledHeader(controller.view, imageDirectory: imageDirectory, failures: &failures)
                }
                if phase == "settled", imageDirectory != nil || auditHeaderColor {
                    let bounds = controller.view.bounds
                    if let rep = controller.view.bitmapImageRepForCachingDisplay(in: bounds) {
                        controller.view.cacheDisplay(in: bounds, to: rep)
                        if auditHeaderColor, model.route != .about {
                            let sx = CGFloat(rep.pixelsWide) / bounds.width
                            let sy = CGFloat(rep.pixelsHigh) / bounds.height
                            let sampleY = Int((insets.top + Theme.topInset / 2) * sy)
                            if let outer = rep.colorAt(x: Int(insets.left / 2 * sx), y: sampleY)?.usingColorSpace(.deviceRGB),
                               let header = rep.colorAt(x: Int((insets.left + Theme.contentPadding / 2) * sx), y: sampleY)?.usingColorSpace(.deviceRGB) {
                                let delta = max(abs(outer.redComponent - header.redComponent),
                                                abs(outer.greenComponent - header.greenComponent),
                                                abs(outer.blueComponent - header.blueComponent))
                                if delta > 2.0 / 255 {
                                    failures.append("\(name) title background color differs: \(delta)")
                                }
                            } else { failures.append("\(name) cannot sample title background") }
                        }
                        if let imageDirectory, let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: imageDirectory).appendingPathComponent("\(name).png"))
                        }
                    }
                }
                print("\(name) \(phase): \(Int(window.frame.width))×\(Int(window.frame.height)), \(scrollCount) scroll views")
            }
            popover.close()
        }
        anchor.orderOut(nil)
        if let path = CommandLine.arguments.first(where: { $0.hasPrefix("--audit-output=") }) {
            let url = URL(fileURLWithPath: String(path.dropFirst("--audit-output=".count)))
            if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
            }
        }
        failures.forEach { print("LAYOUT FAIL: \($0)") }
        print("native popover audit: \(scenes.count) scenes, \(scenes.count * 2) layout phases, \(failures.count) failures")
        if !failures.isEmpty { exit(2) }
    }

    @MainActor private static func auditScrolledHeader(_ view: NSView, imageDirectory: String?, failures: inout [String]) {
        func firstScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(firstScroll).first
        }
        func snapshot() -> NSBitmapImageRep? {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        guard let scroll = firstScroll(view), let before = snapshot() else {
            failures.append("scrolled header fixture missing"); return
        }
        let original = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: 0, y: original.y + 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        guard let after = snapshot() else { failures.append("scrolled header snapshot missing"); return }
        let sx = CGFloat(after.pixelsWide) / view.bounds.width
        let sy = CGFloat(after.pixelsHigh) / view.bounds.height
        let insets = view.safeAreaInsets
        let left = Int(insets.left * sx), right = Int((insets.left + Theme.compactWidth) * sx)
        let top = Int(insets.top * sy)
        let bottom = Int((insets.top + Theme.topInset + Theme.globalTitleHeight) * sy)
        var changed = 0
        for y in top..<bottom {
            for x in left..<right {
                guard let a = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                       abs(a.blueComponent - b.blueComponent)) > 2.0 / 255 { changed += 1 }
            }
        }
        print("scrolled header: \(changed) changed pixels in protected title region")
        if changed > 8 { failures.append("scroll content leaked into title: \(changed) pixels") }
        if let imageDirectory, let data = after.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: imageDirectory).appendingPathComponent("controls-scrolled.png"))
        }
        scroll.contentView.scroll(to: original)
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }


}

@MainActor
final class Renderer {
    let outputDirectory: String
    let dark: Bool
    let pages: Set<String>?
    var written: [String] = []
    var horizontalOverflow: [String] = []
    var layoutMetrics: [[String: Any]] = []

    init(outputDirectory: String, dark: Bool, pages: Set<String>? = nil) {
        self.outputDirectory = outputDirectory
        self.dark = dark
        self.pages = pages
    }

    func renderAll() {
        let fixtures = Fixtures()
        render("01-overview-light", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.connected(tab: 0))
        }
        render("02-devices", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.connected(tab: 1))
        }
        render("03-devices-filtered", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 1)
            model.searchQuery = "i"
            model.accessFilter = .wifi5G
            return ShellView(model: model)
        }
        render("04-controls", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.connected(tab: 2))
        }
        render("05-sms-inbox", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.connected(tab: 3))
        }
        render("06-sms-compose", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 3)
            model.selectedThreadID = "10010"
            model.smsRoute = .thread
            return ShellView(model: model)
        }
        render("07-sms-new-chat", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 3)
            model.selectedThreadID = nil
            model.smsRoute = .thread
            return ShellView(model: model)
        }
        render("08-connect", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.firstRun())
        }
        render("09-cellular", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 0)
            model.route = .cellular
            return ShellView(model: model)
        }
        render("11-cellular-cells", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 0)
            model.route = .cellular
            model.cellularTab = 1
            return ShellView(model: model)
        }
        render("10-offline", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.offline())
        }
        render("12-controls-error", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 2)
            model.notices.show("操作失败：设备返回 400（set_single_by_xmlnode 被拒绝）", tone: .error)
            return ShellView(model: model)
        }
        render("13-sms-error", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 3)
            model.notices.show("短信读取失败：请求超时", tone: .error)
            return ShellView(model: model)
        }
        render("14-overview-ethernet-nocard", width: Theme.compactWidth, height: Theme.compactHeight) {
            ShellView(model: fixtures.ethernetNoSim())
        }
        render("15-about", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 0)
            model.route = .about
            return ShellView(model: model)
        }
        for (number, tab) in [(16, 1), (17, 3)] {
            render("\(number)-offline-\(tab == 1 ? "devices" : "sms")", width: Theme.compactWidth, height: Theme.compactHeight) {
                let model = fixtures.connected(tab: tab)
                model.data.connected = false
                return ShellView(model: model)
            }
        }
        render("18-offline-cellular", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 0)
            model.route = .cellular
            model.data.connected = false
            return ShellView(model: model)
        }
        render("19-lock-controls", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 0)
            model.route = .cellular; model.cellularTab = 1
            model.radioLocks = RadioLockState(cells: [LockedCell(index: 1, act: 2, arfcn: 634464, pci: 101)], lteBands: [1, 3], nrBands: [78])
            return ShellView(model: model)
        }
        render("20-offline-controls", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 2)
            model.data.connected = false
            return ShellView(model: model)
        }
        render("21-controls-network", width: Theme.compactWidth, height: Theme.compactHeight,
               scrollToBottom: true) {
            ShellView(model: fixtures.connected(tab: 2))
        }
        for (name, route) in [("22-ddns", ShellView.Route.ddns), ("23-port-mapping", .portMapping),
                              ("24-offline-ddns", .ddns), ("25-offline-port-mapping", .portMapping)] {
            render(name, width: Theme.compactWidth, height: Theme.compactHeight) {
                let model = fixtures.connected(tab: 2)
                model.route = route
                if name.contains("offline") { model.data.connected = false }
                return ShellView(model: model)
            }
        }
        render("26-devices-long-name", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 1)
            model.devices[0].name = String(repeating: "LongDeviceName", count: 5)
            return ShellView(model: model)
        }
        for (name, settleTime) in [("27-sms-long-thread", 0.4), ("28-sms-first-entry", 0.02),
                                   ("29-sms-thread-status", 0.4)] {
            render(name, width: Theme.compactWidth, height: Theme.compactHeight, settleTime: settleTime) {
                let model = fixtures.connected(tab: 3)
                model.threads = fixtures.longThreads()
                model.selectedThreadID = "10010"; model.smsRoute = .thread
                if name == "29-sms-thread-status" {
                    model.notices.show("短信读取失败：连接暂时中断，请重新连接设备后重试。", tone: .error)
                }
                return ShellView(model: model)
            }
        }
        render("30-sms-long-number", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 3)
            let thread = fixtures.longNumberThread()
            model.threads = [thread]; model.selectedThreadID = thread.id; model.smsRoute = .thread
            return ShellView(model: model)
        }
        render("31-notice-bubbles", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 0)
            model.notices.show("短信已发送", tone: .success)
            model.notices.show("连接已断开，请重新连接设备", tone: .error)
            return ShellView(model: model)
        }
        render("32-band-chips", width: Theme.compactWidth, height: Theme.compactHeight,
               scrollToBottom: true) {
            let model = fixtures.connected(tab: 0)
            model.route = .cellular
            model.radioLocks = RadioLockState(lteBands: [1, 3, 8], nrBands: [41, 78])
            return ShellView(model: model)
        }
        render("33-rebooting", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 2)
            model.data.connected = false
            model.settings = nil
            model.rebooting = true
            return ShellView(model: model)
        }
        render("34-device-reservation", width: Theme.compactWidth, height: Theme.compactHeight) {
            let model = fixtures.connected(tab: 1)
            model.devices[0].mac = "02:00:00:00:00:10"
            model.reservations = [try! DHCPReservation(mac: "02:00:00:00:00:10", ip: "192.168.8.101", index: 1)]
            return ShellView(model: model)
        }
    }

    func render(_ name: String, width: CGFloat, height: CGFloat, scrollToBottom: Bool = false,
                settleTime: TimeInterval = 0.4,
                @ViewBuilder body: () -> some View) {
        guard pages?.contains(name) != false else { return }
        let root = body()
            .frame(width: width, height: height)
            .background(dark ? Color.black : Color.white)
        // Match the application's safe-area and scroll configuration. A plain hosting
        // view can misplace a nested page's safe-area bars in a borderless window.
        let controller = PopoverHostingController(rootView: ForcedAppearance(content: root, dark: dark),
                                                 designSize: NSSize(width: width, height: height))
        let hosting = controller.view
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its layout and any material/gradient passes.
        RunLoop.main.run(until: Date().addingTimeInterval(settleTime))
        hosting.layoutSubtreeIfNeeded()
        if settleTime > 0.1 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

        let scrollers = scrollViews(in: hosting)
        for scroller in scrollers {
            guard let document = scroller.documentView, scroller.contentSize.width > 0 else { continue }
            let extra = document.frame.width - scroller.contentSize.width
            let insets = scroller.contentInsets
            let phoneOverflow = isPhoneOverflow(scroller, page: name)
            layoutMetrics.append(["page": name, "document": NSStringFromRect(document.frame),
                                  "viewport": NSStringFromSize(scroller.contentSize),
                                  "unobscuredHeight": scroller.contentSize.height - insets.top - insets.bottom,
                                  "topInset": insets.top, "bottomInset": insets.bottom,
                                  "horizontalOverflow": extra,
                                  "intentionalPhoneScrolling": phoneOverflow,
                                  "horizontalElasticity": scroller.horizontalScrollElasticity.rawValue,
                                  "scrollerStyle": scroller.scrollerStyle.rawValue,
                                  "hasHorizontalScroller": scroller.hasHorizontalScroller,
                                  "reservedScrollerWidth": max(0, scroller.bounds.width - scroller.contentSize.width),
                                  "horizontalOrigin": scroller.contentView.bounds.minX,
                                  "verticalOverflow": max(0, document.frame.height + insets.top + insets.bottom - scroller.contentSize.height)])
            if extra > 2, !phoneOverflow { horizontalOverflow.append("\(name): horizontal overflow \(extra) pt") }
        }
        if scrollToBottom, let scroller = scrollers.first, let document = scroller.documentView {
            let bottom = document.isFlipped
                ? max(-scroller.contentInsets.top, document.frame.height - scroller.contentSize.height + scroller.contentInsets.bottom)
                : -scroller.contentInsets.bottom
            scroller.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroller.reflectScrolledClipView(scroller.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        // `cacheDisplay` runs in the view's own coordinate space, which keeps text
        // upright; `layer.render(in:)` would double-apply the non-flipped NSView origin.
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        hosting.cacheDisplay(in: bounds, to: rep)
        let path = (outputDirectory as NSString).appendingPathComponent("\(name).png")
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            written.append(path)
        }
        window.orderOut(nil)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }

}

private struct ForcedAppearance<Content: View>: View {
    let content: Content
    let dark: Bool
    var body: some View {
        content
            .preferredColorScheme(dark ? .dark : .light)
            .environment(\.fhcpemGlassEnabled, false)
    }
}

// MARK: - Fixtures

@MainActor
struct Fixtures {
    func snapshot() -> DeviceSnapshot {
        var s = DeviceSnapshot()
        s.model = "LG6851F"
        s.firmware = "RP0112"
        s.network = "5G"
        s.activeTech = .nr
        s.nrMode = "SA"
        s.manufacturer = "FiberHome"
        s.operatorName = "Unicom"
        s.smsCount = 28
        s.uptime = "18460"
        s.wanConnected = true
        s.ethernetConnected = false
        s.ethernetAddress = nil
        s.wanAddress = "198.51.100.21"
        s.uplinkEvidence = "蜂窝已连接 · 以太网未接入"
        s.temperature = "31.7"
        s.plmn = "46001"
        s.uplink = .cellular
        s.uplinkAvailable = true
        s.signalBars = 4
        s.nr.rsrp = "-83"
        s.nr.rssi = "-68"
        s.nr.qci = "8"
        s.nr.cqi = "12"
        s.nr.power = "-1"
        s.nr.dlAmbrKbps = 512000
        s.nr.ulAmbrKbps = 102400
        s.nr.rsrq = "-12"
        s.nr.sinr = "7"
        s.nr.band = "n78"
        s.nr.pci = "101"
        s.nr.cell = "70000000001"
        s.nr.tac = "42"
        s.nr.plmn = "46001"
        s.nr.arfcn = "634464"
        s.downloadBps = 102_400_000
        s.uploadBps = 12_800_000
        s.todayBytes = 9_420_000_000
        s.monthBytes = 126_800_000_000
        s.devicesKnown = true
        s.deviceCount = 9
        return s
    }

    func devices() -> [ConnectedDevice] {
        [
            .init(id: "1", name: "MacBook Pro", ip: "192.168.8.101", access: .wired, deviceType: "laptop"),
            .init(id: "2", name: "iPhone", ip: "192.168.8.102", access: .wifi5G, deviceType: "phone"),
            .init(id: "3", name: "Demo-Device-b42402", ip: "192.168.8.103", access: .wifi24G, hostname: "Demo-Device-2841e0"),
            .init(id: "4", name: "客厅电视", ip: "192.168.8.104", access: .wired, deviceType: "tv"),
            .init(id: "5", name: "Demo-Device-ecbea2", ip: "192.168.8.105", access: .wifi24G, deviceType: "game"),
            .init(id: "6", name: "MacBook Air", ip: "192.168.8.109", access: .wifi5G, deviceType: "laptop"),
            .init(id: "7", name: "客厅平板", ip: "192.168.8.110", access: .wifi5G, deviceType: "tablet"),
            .init(id: "8", name: "Demo-Device-43d125", ip: "192.168.8.111", access: .wired, deviceType: "desktop"),
            .init(id: "9", name: "Demo-Device-b98d85", ip: "192.168.8.112", access: .wifi24G)
        ]
    }

    func cells() -> [CellRecord] {
        [
            .init(tech: .nr, band: "N78", pci: "101", channel: "634464", rsrp: "-83", sinr: "7", state: .serving),
            .init(tech: .nr, band: "N78", pci: "102", channel: "634464", rsrp: "-89", sinr: "1", state: .neighbor),
        .init(tech: .nr, band: "N78", pci: "103", channel: "634464", rsrp: "-101", sinr: "-8", state: .neighbor)
        ]
    }

    func settings() -> DeviceSettings {
        var s = DeviceSettings()
        s.currentWANDevice = UplinkTarget.cellularDevice
        s.aggregationEnabled = false
        s.wifi = [
            .init(id: 1, ssid: "FHCPEM-DEMO-2G", enabled: true, band: "2.4G", security: "WPA2-PSK"),
            .init(id: 2, ssid: "FHCPEM-DEMO-WIFI", enabled: false, band: "2.4G", security: "WPA2-PSK"),
            .init(id: 5, ssid: "FHCPEM-DEMO-5G", enabled: true, band: "5G", security: "WPA3-SAE"),
            .init(id: 6, ssid: "FHCPEM-DEMO-5G", enabled: false, band: "5G", security: "WPA2-PSK")
        ]
        s.rebootEnabled = true
        s.rebootTime = "04:30"
        s.rebootWeekday = "Sunday"
        s.ledOn = true
        s.fanMode = "2"
        s.mloGroups = 0
        return s
    }

    func threads() -> [SMSThread] {
        [
            SMSThread(phone: "10010", messages: [
                .init(id: "1", sender: "10010", body: "合成测试通知 32fc：演示套餐剩余 42 GB，仅用于界面与测试。", date: "2026/10/09 10:12:00", isRead: true),
                .init(id: "send-1", sender: "10010", body: "流量查询", date: "2026/10/09 13:58:10", isRead: true, isSent: true, childnode: "1"),
                .init(id: "2", sender: "10010", body: "合成测试通知 2a90：演示套餐剩余 42 GB，仅用于界面与测试。", date: "2026/10/09 13:58:55", isRead: false)
            ]),
            SMSThread(phone: "服务通知", messages: [
                .init(id: "3", sender: "服务通知", body: "您的设备已完成固件升级。", date: "2026/10/08 09:00:00", isRead: true)
            ])
        ]
    }

    func longThreads() -> [SMSThread] {
        [SMSThread(phone: "10010", messages: (1...60).map { index in
            SMSMessage(id: "long-\(index)", sender: "10010",
                       body: index == 60
                           ? String(repeating: "【流量提醒】本条消息用于检查首次进入会话时完整正文与日期的排布。", count: 8)
                           : "历史短信 \(index)：当前已使用流量 126.8 GB，剩余 73.2 GB。",
                       date: "2026/10/18 23:58:55", isRead: true, isSent: index % 3 == 0)
        })]
    }

    func connected(tab: Int) -> ShellModel {
        let model = ShellModel(route: .main, tab: tab,
                               data: PageData(snapshot: snapshot(), devices: devices(), stale: false, connected: true),
                               devices: devices(), cells: cells(), lockMode: .automatic)
        model.settings = settings()
        let wan = WANConnectionRef(device: 1, link: .ipoe, name: "1_INTERNET_R_VID_", enabled: true)
        model.mobileNetwork = MobileNetworkState(airplaneMode: false, cellularDataEnabled: true,
                                                antennaEnabled: true, antennaType: .n78n77, cellularWAN: wan)
        model.wanConnections = [wan]
        model.ddnsLoaded = true; model.portMappingsLoaded = true
        model.ddnsEntries = [DDNSEntry(wan: wan, index: 1, provider: "dyndns", hostname: "example.invalid",
                                       username: "example", password: "fixture-only", enabled: false)]
        model.portMappings = [PortMappingEntry(wan: wan, index: 1, localIP: "192.168.8.120",
                                               internalPort: 8080, internalEnd: 8080,
                                               externalPort: 18080, externalEnd: 18080,
                                               proto: .tcp, enabled: false)]
        model.threads = threads()
        model.smsLastSync = Date()
        return model
    }

    func ethernetNoSim() -> ShellModel {
        var s = DeviceSnapshot()
        s.model = "LG6851F"
        s.firmware = "RP0112"
        s.network = ""
        s.activeTech = .unknown
        s.manufacturer = "FiberHome"
        s.uptime = "86400"
        s.wanConnected = false
        s.ethernetConnected = true
        s.ethernetAddress = "192.168.1.58"
        s.wanAddress = nil
        s.uplink = .broadband
        s.uplinkAvailable = true
        s.signalBars = nil
        s.temperature = "29.4"
        s.downloadBps = 245_000_000
        s.uploadBps = 38_000_000
        s.todayBytes = 4_200_000_000
        s.monthBytes = 58_000_000_000
        s.devicesKnown = true
        s.deviceCount = 9
        return ShellModel(route: .main, tab: 0,
                          data: PageData(snapshot: s, devices: devices(), stale: false, connected: true),
                          devices: devices(), cells: [], lockMode: .automatic)
    }

    func offline() -> ShellModel {
        ShellModel(route: .main, tab: 0, data: PageData(snapshot: nil, devices: [], stale: true, connected: false))
    }

    func firstRun() -> ShellModel {
        ShellModel(route: .connect)
    }

    func longNumberThread() -> SMSThread {
        let phone = "+" + String(repeating: "1234567890", count: 4)
        return SMSThread(phone: phone, messages: [
            SMSMessage(id: "synthetic-long-number", sender: phone, body: "用于检查超长号码的合成短信。",
                       date: "2026/01/01 12:00:00", isRead: true, isSent: false)
        ])
    }
}

/// Only the explicit long-number fixture may contain a narrow horizontal scroller.
/// Its viewport must remain centered and within the title's 220 pt maximum.
@MainActor private func isPhoneOverflow(_ scroll: NSScrollView, page: String) -> Bool {
    guard page.contains("sms-long-number"), let document = scroll.documentView else { return false }
    return scroll.contentSize.width <= 220.5 && scroll.contentSize.height <= 20
        && document.frame.width > scroll.contentSize.width + 2
}

import SwiftUI
import AppKit
import FHCPECore

/// The popover shell. It owns nothing about networking: a `ShellModel` supplies state and
/// callbacks so the layout can be rendered (and screenshot-tested) without a session.
public struct ShellView: View {
    private static var canvasSpace: String { "fhcpem.shellCanvas" }
    public enum Route: Equatable, Sendable {
        case connect, main, cellular, about, ddns, portMapping
    }

    @Bindable public var model: ShellModel

    public init(model: ShellModel) { self.model = model }

    public var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                content
                    .containerBackground(.clear, for: .window)
            } else {
                content
            }
        }
        // The hosting controller isolates the native arrow safe area from this fixed
        // page canvas. Only the backdrop extends into the surrounding native margin.
        .frame(width: Theme.compactWidth, height: Theme.compactHeight)
        .coordinateSpace(name: Self.canvasSpace)
        .overlay(alignment: .top) {
            AppNoticeStack(center: model.notices)
                .padding(.horizontal, Theme.contentPadding)
                .padding(.top, model.route == .about ? Theme.topInset
                         : Theme.topInset + Theme.globalTitleHeight + Theme.globalTitleGap)
        }
        .animation(nil, value: model.tab)
        .animation(nil, value: model.route)
        .animation(nil, value: model.smsRoute)
        .scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                VisualEffectBackground()
                Theme.canvasBackdrop
            }
            .ignoresSafeArea()
        )
        .environment(\.appNotices, model.notices)
        .onReceive(NotificationCenter.default.publisher(for: .firmwareRowsSkipped).receive(on: RunLoop.main)) { notification in
            if let message = notification.userInfo?["message"] as? String {
                model.notices.show(message, tone: .info)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if model.route == .connect {
                globalTitle
                    .padding(.top, Theme.topInset)
                    .padding(.bottom, Theme.globalTitleGap)
                ConnectPage(address: $model.draftAddress, username: $model.draftUsername,
                            password: $model.draftPassword,
                            savePassword: $model.savePassword,
                            busy: model.busy, error: model.connectError ?? model.statusMessage,
                            onConnect: model.connect,
                            onDetectGateway: model.detectGateway)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                navigatedCanvas
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.tab) { _, tab in
            // Tab entry requests a quiet read; the independent three-second sampler
            // never switches the controls into a user-write busy state.
            if tab == 1, model.route == .main { model.onDevicesSelected() }
            if tab == 2, model.route == .main { model.onControlsSelected() }
            if tab == 3, model.route == .main { model.onSMSSelected() }
        }
    }

    @ViewBuilder private var navigatedCanvas: some View {
        if model.rebooting {
            VStack(spacing: Theme.tabBarGap) {
                titledCanvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                navigationBar
            }
        } else if #available(macOS 26.0, *) {
            titledCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .bottom, spacing: Theme.tabBarGap) { navigationBar }
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            titledCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: Theme.tabBarGap) { navigationBar }
        }
    }

    @ViewBuilder private var titledCanvas: some View {
        if model.route == .about {
            canvas.padding(.top, Theme.topInset)
        } else if model.rebooting {
            // Plain waiting states have no scroll view to consume a safe-area bar.
            VStack(spacing: Theme.globalTitleGap) {
                titleBar
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if #available(macOS 26.0, *) {
            protectedCanvas.safeAreaBar(edge: .top, spacing: Theme.globalTitleGap) {
                titleBar
            }
        } else {
            protectedCanvas.safeAreaInset(edge: .top, spacing: Theme.globalTitleGap) {
                titleBar
            }
        }
    }

    /// Fade moving content out beneath the title without tinting the shared backdrop.
    /// A page already placed below the title receives an entirely opaque mask.
    private var protectedCanvas: some View {
        canvas.mask {
            GeometryReader { geometry in
                let origin = geometry.frame(in: .named(Self.canvasSpace)).minY
                let titleEnd = Theme.topInset + Theme.globalTitleHeight
                let clearEnd = max(0, titleEnd - origin)
                let fadeEnd = max(0, titleEnd + Theme.globalTitleGap - origin)
                let height = max(1, geometry.size.height)
                if fadeEnd > 0 {
                    LinearGradient(colors: [.clear, .black],
                                   startPoint: UnitPoint(x: 0.5, y: clearEnd / height),
                                   endPoint: UnitPoint(x: 0.5, y: fadeEnd / height))
                } else { Color.black }
            }
        }
    }

    private var titleBar: some View {
        // The content mask protects this region even when NSPopover does not draw
        // the system scroll-edge effect. The title uses the shared shell backdrop.
        globalTitle.padding(.top, Theme.topInset)
            .background {
                // Concealed controls must not receive clicks through the title band.
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { }
                    .accessibilityHidden(true)
            }
    }

    private var globalTitle: some View {
        Text("FiberHome CPE Manager")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Theme.contentPadding)
            .frame(height: Theme.globalTitleHeight, alignment: .center)
            .accessibilityAddTraits(.isHeader)
    }

    private var navigationBar: some View {
        BottomGlassTabBar(items: Self.tabItems, selection: tabSelection,
                          deviceCount: model.data.isLive ? model.data.devices.count : nil,
                          unread: model.data.isLive ? model.threads.reduce(0) { $0 + $1.unreadCount } : 0)
            .padding(.bottom, Theme.tabBarBottomInset)
    }

    /// Switching tabs must leave any drill-in page, so the header never shows a stale title.
    private var tabSelection: Binding<Int> {
        Binding(get: { model.tab }, set: { newValue in
            model.tab = newValue
            model.smsRoute = .threads
            model.selectedThreadID = nil
            if model.route == .cellular { model.closeCellular() }
            if model.route == .ddns { model.closeDDNS() }
            if model.route == .portMapping { model.closePortMapping() }
            if model.route == .about {
                model.closeAbout()
                if model.route != .connect { model.route = .main }
            }
        })
    }

    private var canvas: some View {
        Group {
            switch model.route {
            case .connect:
                EmptyView()
            case .about:
                AboutPage(onBack: model.closeAbout)
            case .ddns:
                DDNSPage(model: model)
            case .portMapping:
                PortMappingPage(model: model)
            case .cellular:
                CellularDetailPage(data: model.data, cells: model.data.isLive ? model.cells : [], lockMode: model.data.isLive ? model.lockMode : .unknown,
                                   lockBusy: model.lockBusy, onBack: model.closeCellular,
                                   onRefreshCells: model.refreshCells, onLockCurrent: model.applyLock,
                                   initialTab: model.cellularTab,
                                   lockState: model.data.isLive ? model.radioLocks : nil,
                                   onSetCellLockEnabled: model.setCellLockEnabled,
                                   onSetBandLockEnabled: model.setBandLockEnabled,
                                   onAddLockedCell: model.addLockedCell,
                                   onUpdateLockedCell: model.updateLockedCell,
                                   onDeleteLockedCell: model.deleteLockedCell,
                                   onDisableLocks: model.disableLocks)
            case .main:
                switch model.tab {
                case 1:
                    DevicesPage(devices: model.devices, isLive: model.data.isLive,
                                query: $model.searchQuery, filter: $model.accessFilter,
                                onReload: model.refreshNow, onReserveIP: model.reserveIP,
                                onRemoveReservation: model.removeReservation, reservations: model.reservations)
                case 2:
                    ControlsPage(settings: model.data.isLive ? model.settings : nil,
                                 busy: model.settingsBusy,
                                 isLive: model.data.isLive,
                                 onToggleSSID: model.toggleSSID,
                                 onRenameSSID: model.renameSSID,
                                 onSaveReboot: model.saveReboot,
                                 onSaveLED: model.saveLED,
                                 onSaveFan: model.saveFan,
                                 switchingTo: model.uplinkSwitchTarget,
                                 onSwitchUplink: model.switchUplink,
                                 mobile: model.data.isLive ? model.mobileNetwork : nil,
                                 onSetAirplaneMode: model.setAirplaneMode,
                                 onSetCellularData: model.setCellularData,
                                 onSaveAntenna: model.saveAntenna,
                                 ddnsCount: model.data.isLive && model.ddnsLoaded ? model.ddnsEntries.count : nil,
                                 portMappingCount: model.data.isLive && model.portMappingsLoaded ? model.portMappings.count : nil,
                                 onOpenDDNS: model.openDDNS,
                                 onOpenPortMapping: model.openPortMapping,
                                 onRebootDevice: model.rebootDevice, rebooting: model.rebooting)
                case 3:
                    SMSPage(threads: model.threads, route: model.smsRoute,
                            selectedThread: model.threads.first { $0.id == model.selectedThreadID },
                            busy: model.smsBusy,
                            lastSync: model.smsLastSync, isLive: model.data.isLive,
                            draftNumber: $model.draftNumber, draftBody: $model.draftBody,
                            replyBody: $model.replyBody,
                            onReload: model.reloadMessages, onSend: model.sendSMS,
                            onSelect: { thread in
                                model.selectedThreadID = thread.id
                                model.smsRoute = .thread
                                model.replyBody = ""
                                model.draftBody = ""
                            },
                            onBack: {
                                model.smsRoute = .threads
                                model.selectedThreadID = nil
                                model.replyBody = ""
                                model.draftBody = ""
                            },
                            onCompose: {
                                model.selectedThreadID = nil
                                model.draftNumber = ""
                                model.draftBody = ""
                                model.replyBody = ""
                                model.smsRoute = .thread
                            },
                            onMarkRead: model.markThreadRead,
                            onSendReply: model.sendReply)
                default:
                    OverviewPage(data: model.data, onMoreInfo: model.openCellular)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let tabItems: [BottomGlassTabBar.Item] = [
        .init(id: 0, title: "概览", symbol: "antenna.radiowaves.left.and.right"),
        .init(id: 1, title: "设备", symbol: "laptopcomputer.and.iphone"),
        .init(id: 2, title: "控制", symbol: "slider.horizontal.3"),
        .init(id: 3, title: "短信", symbol: "message.fill")
    ]
}

/// Observable view model for the shell. The concrete app subclasses/feeds this with a
/// live `DeviceSession`; the renderer feeds it fixtures.
@MainActor @Observable public final class ShellModel {
    public let notices = AppNoticeCenter()
    public var route: ShellView.Route
    public var tab: Int
    public var data: PageData
    public var rebooting = false
    public var rebootDevice: () -> Void = {}
    public var reservations: [DHCPReservation] = []
    public var removeReservation: (@MainActor (ConnectedDevice) async throws -> Void)?
    public var ddnsEditorPresented = false
    public var portMappingEditorPresented = false
    var ddnsDraft = DDNSDraft()
    var portMappingDraft = PortMappingDraft()
    var editingDDNS: DDNSEntry?
    var editingPortMapping: PortMappingEntry?
    public var advancedSaving = false
    @ObservationIgnored var advancedTask: Task<Void, Never>?
    public var devices: [ConnectedDevice]
    public var cells: [CellRecord]
    public var lockMode: LockMode
    public var lockBusy = false
    public var radioLocks: RadioLockState?

    /// Which segment the cellular page opens on (renderer/test seam).
    public var cellularTab = 0
    public var busy = false

    public var mobileNetwork: MobileNetworkState?
    public var wanConnections: [WANConnectionRef] = []
    public var ddnsEntries: [DDNSEntry] = []
    public var portMappings: [PortMappingEntry] = []
    public var ddnsLoaded = false
    public var portMappingsLoaded = false
    public var advancedBusy = false


    public var draftAddress: String
    public var draftUsername: String
    public var draftPassword: String
    /// Menu-bar display style; changed only from the right-click menu.
    public var menuBarStyle: MenuBarStyle = .default
    /// Bare host of the connected device.
    public var lanAddress: String = ""
    public var connectError: String?
    /// Connection progress shown while the device is temporarily unavailable.
    public var statusMessage: String?

    public var searchQuery = ""
    public var accessFilter: DevicesPage.AccessFilter = .all
    public var smsRoute: SMSPage.Route = .threads
    /// SMS conversations from `get_sms_data`, newest first.
    public var threads: [SMSThread] = []
    public var selectedThreadID: String?
    public var smsBusy = false
    /// Settings hub state.
    public var settings: DeviceSettings?
    public var settingsBusy = false
    /// The mode being switched to, shown as a spinner on its card.
    public var uplinkSwitchTarget: UplinkTarget?
    public var switchUplink: (UplinkTarget) -> Void = { _ in }
    public var draftNumber = ""
    public var draftBody = ""

    /// Last successful get_sms_data read; shown as a subtle sync stamp on the SMS list.
    public var smsLastSync: Date?

    // Callbacks injected by the app layer; no-ops for previews.
    public var connect: () -> Void = {}
    public var openCellular: () -> Void = {}
    public var closeCellular: () -> Void = {}
    public var closeAbout: () -> Void = {}
    public var setAirplaneMode: (Bool) -> Void = { _ in }
    public var setCellularData: (Bool) -> Void = { _ in }
    public var saveAntenna: (Bool, AntennaType) -> Void = { _, _ in }
    public var openDDNS: () -> Void = {}
    public var closeDDNS: () -> Void = {}
    public var reloadDDNS: () -> Void = {}
    public var saveDDNS: (DDNSEntry?, DDNSInput) async throws -> Void = { _, _ in throw CPEError.authentication }
    public var deleteDDNS: (DDNSEntry) async throws -> Void = { _ in throw CPEError.authentication }
    public var setDDNSEnabled: (DDNSEntry, Bool) async throws -> Void = { _, _ in throw CPEError.authentication }
    public var openPortMapping: () -> Void = {}
    public var closePortMapping: () -> Void = {}
    public var reloadPortMappings: () -> Void = {}
    public var addPortMapping: (PortMappingInput) async throws -> Void = { _ in throw CPEError.authentication }
    public var updatePortMapping: (PortMappingEntry, PortMappingInput) async throws -> Void = { _, _ in throw CPEError.authentication }
    public var deletePortMapping: (PortMappingEntry) async throws -> Void = { _ in throw CPEError.authentication }
    public var setPortMappingEnabled: (PortMappingEntry, Bool) async throws -> Void = { _, _ in throw CPEError.authentication }
    public var setCellLockEnabled: (Bool) -> Void = { _ in }
    public var setBandLockEnabled: (Bool, [Int], [Int]) -> Void = { _, _, _ in }
    public var addLockedCell: (LockedCell) -> Void = { _ in }
    public var updateLockedCell: (LockedCell) -> Void = { _ in }
    public var deleteLockedCell: (LockedCell) -> Void = { _ in }
    public var disableLocks: () -> Void = {}
    public var reserveIP: (@MainActor (ConnectedDevice, String) async throws -> Void)?
    public var refreshCells: () -> Void = {}
    public var applyLock: (CellRecord?) -> Void = { _ in }
    public var reloadMessages: () -> Void = {}
    public var sendSMS: () -> Void = {}
    public var markThreadRead: (SMSThread) -> Void = { _ in }
    public var sendReply: (SMSThread, String) -> Void = { _, _ in }
    /// Mirrors the login page's Keychain opt-in; applied on a successful connect.
    public var savePassword = false
    public var detectGateway: () -> Void = {}
    /// Text of the inline reply box (cleared when the conversation is left or sent).
    public var replyBody = ""
    public var toggleSSID: (WiFiNetwork, Bool) -> Void = { _, _ in }
    public var renameSSID: (WiFiNetwork, String) -> Void = { _, _ in }
    public var saveReboot: (Bool, String, String) -> Void = { _, _, _ in }
    public var saveLED: (Bool) -> Void = { _ in }
    public var saveFan: (FanMode) -> Void = { _ in }
    /// Fired when the controls tab becomes visible, so settings are read on entry rather
    /// than on every 1 Hz traffic refresh.
    public var onDevicesSelected: () -> Void = {}
    public var onControlsSelected: () -> Void = {}
    /// Fired when the SMS tab becomes visible, so the first get_sms_data read is immediate.
    public var onSMSSelected: () -> Void = {}
    public var quit: () -> Void = {}
    public var refreshNow: () -> Void = {}

    public init(route: ShellView.Route = .connect, tab: Int = 0, data: PageData = PageData(snapshot: nil),
                devices: [ConnectedDevice] = [], cells: [CellRecord] = [], lockMode: LockMode = .automatic,
                address: String = "192.168.8.1", username: String = "admin", password: String = "",
                menuBarStyle: MenuBarStyle = .default) {
        self.route = route; self.tab = tab; self.data = data; self.devices = devices
        self.cells = cells; self.lockMode = lockMode
        self.draftAddress = address; self.draftUsername = username; self.draftPassword = password
        self.menuBarStyle = menuBarStyle

    }

    /// Explicit disconnect/router changes reset drafts; stale samples never do.
    public func resetSession() {
        advancedTask?.cancel(); advancedTask = nil
        data = PageData(snapshot: nil)
        devices = []; cells = []; settings = nil; radioLocks = nil; lockMode = .unknown
        threads = []; selectedThreadID = nil; smsRoute = .threads; smsLastSync = nil
        draftNumber = ""; draftBody = ""; replyBody = ""
        smsBusy = false; settingsBusy = false; lockBusy = false; uplinkSwitchTarget = nil
        rebooting = false
        mobileNetwork = nil; wanConnections = []; ddnsEntries = []; portMappings = []
        reservations = []
        ddnsLoaded = false; portMappingsLoaded = false
        advancedBusy = false; advancedSaving = false
        dismissDDNSEditor(); dismissPortMappingEditor()
    }
}

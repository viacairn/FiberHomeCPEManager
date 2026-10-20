import SwiftUI
import Foundation

public enum AppNoticeTone: Equatable, Sendable { case info, success, error }

public struct AppNotice: Identifiable {
    public let id: UUID
    public let message: String
    public let tone: AppNoticeTone
    let expiresAt: TimeInterval
    let actionTitle: String?
    let action: (@MainActor () -> Void)?
}

/// One in-memory lifetime for every notification, including while a page is hidden.
@MainActor @Observable public final class AppNoticeCenter {
    public private(set) var notices: [AppNotice] = []
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStatuses: [PendingStatus] = []
    @ObservationIgnored private var latestStatus: [String: UUID] = [:]
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let lifetime: TimeInterval
    @ObservationIgnored private let automaticDismissal: Bool

    public convenience init() { self.init(lifetime: 10) }

    init(lifetime: TimeInterval = 10, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticDismissal: Bool = true) {
        self.lifetime = lifetime; self.now = now; self.automaticDismissal = automaticDismissal
    }

    private struct PendingStatus {
        let id: UUID
        let message: String
        var tone: AppNoticeTone
    }

    deinit { expiryTask?.cancel(); deliveryTask?.cancel() }

    /// Capture events even when a following quiet read clears the status before the
    /// next SwiftUI frame. The adjacent tone assignment finishes the same event.
    func enqueueStatus(_ message: String?, source: String, tone: AppNoticeTone) {
        guard let message else { latestStatus[source] = nil; return }
        let id = UUID()
        latestStatus[source] = id
        pendingStatuses.append(PendingStatus(id: id, message: message, tone: tone))
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.deliverStatuses()
        }
    }

    func updateStatusTone(source: String, tone: AppNoticeTone) {
        guard let id = latestStatus[source], let index = pendingStatuses.firstIndex(where: { $0.id == id }) else { return }
        pendingStatuses[index].tone = tone
    }

    func deliverStatuses() {
        deliveryTask?.cancel(); deliveryTask = nil
        let statuses = pendingStatuses
        pendingStatuses = []; latestStatus = [:]
        for status in statuses { show(status.message, tone: status.tone) }
    }

    public func show(_ message: String, tone: AppNoticeTone = .info,
                     actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notices.removeAll { $0.message == message && $0.tone == tone }
        notices.append(AppNotice(id: UUID(), message: message, tone: tone, expiresAt: now() + lifetime,
                                 actionTitle: actionTitle, action: action))
        scheduleExpiry()
    }

    public func dismiss(_ id: UUID) {
        notices.removeAll { $0.id == id }
        scheduleExpiry()
    }

    func expire() {
        let instant = now()
        notices.removeAll { $0.expiresAt <= instant }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard automaticDismissal, let deadline = notices.map(\.expiresAt).min() else { return }
        let delay = max(0, deadline - now())
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }
}

private struct AppNoticeCenterKey: EnvironmentKey {
    static let defaultValue: AppNoticeCenter? = nil
}

extension EnvironmentValues {
    var appNotices: AppNoticeCenter? {
        get { self[AppNoticeCenterKey.self] }
        set { self[AppNoticeCenterKey.self] = newValue }
    }
}

extension View {
    func appReminder(_ message: String?, tone: AppNoticeTone = .error) -> some View {
        modifier(AppReminder(message: message, tone: tone))
    }

    /// Sheets inherit the center but need their own overlay above the sheet's content.
    func appNoticeOverlay(top: CGFloat = 8) -> some View {
        modifier(AppNoticeOverlay(top: top))
    }
}

private struct AppReminder: ViewModifier {
    @Environment(\.appNotices) private var center
    let message: String?
    let tone: AppNoticeTone
    private struct Value: Equatable { let message: String?; let tone: AppNoticeTone }

    func body(content: Content) -> some View {
        content.onChange(of: Value(message: message, tone: tone), initial: true) { _, value in
            if let message = value.message { center?.show(message, tone: value.tone) }
        }
    }
}

private struct AppNoticeOverlay: ViewModifier {
    @Environment(\.appNotices) private var center
    let top: CGFloat
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let center {
                AppNoticeStack(center: center)
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.top, top)
            }
        }
    }
}

struct AppNoticeStack: View {
    @Bindable var center: AppNoticeCenter
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        if !center.notices.isEmpty {
            if contentHeight > 200 {
                ScrollView(.vertical) { bubbles }
                    .scrollIndicators(.hidden)
                    .frame(height: 200)
            } else {
                bubbles
            }
        }
    }

    private var bubbles: some View {
        VStack(spacing: 6) {
            ForEach(center.notices.reversed()) { notice in bubble(notice) }
        }
        .padding(6)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }

    private func bubble(_ notice: AppNotice) -> some View {
        let tint: Color = switch notice.tone {
        case .info: .accentColor
        case .success: Theme.positive
        case .error: Theme.negative
        }
        let symbol = switch notice.tone {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(height: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(notice.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                if let title = notice.actionTitle, let action = notice.action {
                    Button(title) { center.dismiss(notice.id); action() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { center.dismiss(notice.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭提醒")
            .accessibilityLabel("关闭提醒")
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: shape)
        .background(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(tint.opacity(0.28), lineWidth: 0.75))
        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
    }
}

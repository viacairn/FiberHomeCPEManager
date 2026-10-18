import SwiftUI
import FHCPECore

/// SMS, structured like a mobile messaging app:
/// Level 1 (`threads`): conversation list
/// Level 2 (`thread` / `compose`): unified full-interactive IM chat window that handles both
/// receiving/viewing history and sending messages (including inline recipient entry for new chats).
public struct SMSPage: View {
    public enum Route: Equatable { case threads, thread, compose }

    public let threads: [SMSThread]
    public let route: Route
    public let selectedThread: SMSThread?
    public let busy: Bool
    public let status: String?
    public let statusIsError: Bool
    public let lastSync: Date?
    public let isLive: Bool
    @Binding public var draftNumber: String
    @Binding public var draftBody: String
    /// Text of the inline IM input bar in the conversation window.
    @Binding public var replyBody: String
    public let onReload: () -> Void
    public let onSend: () -> Void
    public let onSelect: (SMSThread) -> Void
    public let onBack: () -> Void
    public let onCompose: () -> Void
    public let onMarkRead: (SMSThread) -> Void
    public let onSendReply: (SMSThread, String) -> Void

    public init(threads: [SMSThread], route: Route, selectedThread: SMSThread?,
                busy: Bool, status: String?, statusIsError: Bool = false,
                lastSync: Date? = nil, isLive: Bool = true,
                draftNumber: Binding<String>, draftBody: Binding<String>,
                replyBody: Binding<String>,
                onReload: @escaping () -> Void, onSend: @escaping () -> Void,
                onSelect: @escaping (SMSThread) -> Void, onBack: @escaping () -> Void,
                onCompose: @escaping () -> Void, onMarkRead: @escaping (SMSThread) -> Void,
                onSendReply: @escaping (SMSThread, String) -> Void) {
        self.threads = threads; self.route = route; self.selectedThread = selectedThread
        self.busy = busy; self.status = status; self.statusIsError = statusIsError
        self.lastSync = lastSync; self.isLive = isLive
        self._draftNumber = draftNumber; self._draftBody = draftBody
        self._replyBody = replyBody
        self.onReload = onReload; self.onSend = onSend
        self.onSelect = onSelect; self.onBack = onBack
        self.onCompose = onCompose; self.onMarkRead = onMarkRead
        self.onSendReply = onSendReply
    }

    /// Resolves either the explicitly selected thread or an existing thread matching the typed recipient number.
    private var activeThread: SMSThread? {
        guard isLive else { return nil }
        if let selectedThread { return selectedThread }
        let trimmed = draftNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return threads.first { $0.phone == trimmed }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isLive {
                switch route {
                case .threads:
                    threadList
                case .thread, .compose:
                    imWindow
                }
            } else {
                disconnectedState
            }
        }
    }

    private var disconnectedState: some View {
        VStack(spacing: 0) {
            PanelHeading("短信会话")
                .padding(.horizontal, Theme.contentPadding)
                .padding(.bottom, Theme.Space.s)
            VStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                Image(systemName: "wifi.slash")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.inkMuted)
                Text("设备已断开连接")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                Text("连接设备后可读取和发送短信")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Level 1: conversations

    private var threadList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                PanelHeading("短信会话")
                if let count = unreadTotal {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel("\(count) 条未读")
                }
                if let lastSync {
                    Text("同步 \(Self.syncTimeFormatter.string(from: lastSync))")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityLabel("短信上次同步 \(Self.syncTimeFormatter.string(from: lastSync))")
                }
                Spacer(minLength: 0)
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 26, height: 26)
                        .background(Theme.panelFill, in: CapsulePanelShape(maxRadius: 999))
                        .overlay(CapsulePanelShape(maxRadius: 999).strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
                        .contentShape(CapsulePanelShape(maxRadius: 999))
                }
                .buttonStyle(.plain)
                .help("重新读取短信")
                .accessibilityLabel("重新读取短信")
                Button(action: onCompose) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 26, height: 26)
                        .background(Theme.panelFill, in: CapsulePanelShape(maxRadius: 999))
                        .overlay(CapsulePanelShape(maxRadius: 999).strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
                        .contentShape(CapsulePanelShape(maxRadius: 999))
                }
                .buttonStyle(.plain)
                .help("新消息")
                .accessibilityLabel("新消息")
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, 0)
            .padding(.bottom, 8)

            if threads.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    Panel(padding: 4, spacing: 0) {
                        ForEach(threads) { thread in
                            threadRow(thread)
                            if thread.id != threads.last?.id {
                                Rectangle()
                                    .fill(Theme.hairline)
                                    .frame(height: 0.5)
                                    .padding(.leading, 48)
                                    .padding(.trailing, 8)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.bottom, Theme.contentPadding)
                }
                .scrollIndicators(.automatic)
            }

            if let status {
                StatusBanner(text: status, tone: statusIsError ? .error : .success)
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.bottom, 6)
            }
        }
    }

    private var unreadTotal: Int? {
        let total = threads.reduce(0) { $0 + $1.unreadCount }
        return total > 0 ? total : nil
    }

    private func threadRow(_ thread: SMSThread) -> some View {
        Button {
            guard isLive else { return }
            onSelect(thread)
            onMarkRead(thread)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.14))
                        Circle().strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 0.75)
                        Text(initial(of: thread.phone))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 32, height: 32)
                    if thread.unreadCount > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8.5, height: 8.5)
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.2))
                            .offset(x: 1, y: -1)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(thread.phone)
                            .font(.system(size: 12.5, weight: thread.unreadCount > 0 ? .bold : .semibold))
                            .foregroundStyle(.primary)
                        if thread.messages.count > 1 {
                            Text("\(thread.messages.count)")
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.inkSecondary)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        Text(shortTime(thread.lastMessage?.date))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    Text(thread.preview)
                        .font(.system(size: 11, weight: thread.unreadCount > 0 ? .medium : .regular))
                        .foregroundStyle(thread.unreadCount > 0
                                         ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(Theme.inkSecondary))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(thread.phone)，\(thread.preview)")
        .accessibilityValue(thread.unreadCount > 0 ? "\(thread.unreadCount) 条未读" : "")
    }

    // MARK: - Level 2: Unified Interactive Mobile IM Window

    private var imWindow: some View {
        VStack(spacing: 0) {
            imHeaderBar

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    if let thread = activeThread, !thread.messages.isEmpty {
                        LazyVStack(spacing: 9) {
                            ForEach(thread.messages) { message in
                                bubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, Theme.contentPadding)
                        .padding(.vertical, 10)
                    } else {
                        imEmptyConversationState
                    }
                }
                .scrollIndicators(.automatic)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: activeThread?.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: activeThread?.id) { _, _ in
                    scrollToBottom(proxy)
                }
            }
            .frame(maxHeight: .infinity)

            imInputBar

            if let status {
                StatusBanner(text: status, tone: statusIsError ? .error : .success)
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.bottom, 4)
            }
        }
    }

    /// Top bar of the IM window: shows the contact number when viewing a thread, or an inline
    /// recipient input capsule when starting a new conversation.
    private var imHeaderBar: some View {
        let pill = CapsulePanelShape(maxRadius: 999)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("会话")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.panelFill, in: pill)
                    .overlay(pill.strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
                    .contentShape(pill)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回短信会话列表")

                if let selectedThread {
                    VStack(spacing: 1) {
                        Text(selectedThread.phone)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("共 \(selectedThread.messages.count) 条消息")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .frame(maxWidth: .infinity)

                    Button(action: onReload) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                            .frame(width: 28, height: 28)
                            .background(Theme.panelFill, in: pill)
                            .overlay(pill.strokeBorder(Theme.hairlineStrong, lineWidth: 0.75))
                            .contentShape(pill)
                    }
                    .buttonStyle(.plain)
                    .help("同步最新短信")
                    .accessibilityLabel("同步最新短信")
                } else {
                    HStack(spacing: 6) {
                        Text("收件人:")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                        TextField("输入号码，例如 10010", text: $draftNumber)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .accessibilityLabel("接收号码")
                        if !draftNumber.isEmpty {
                            Button { draftNumber = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.inkMuted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除接收号码")
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)
                    .background(Theme.panelFill, in: pill)
                    .overlay(pill.strokeBorder(Color.accentColor.opacity(0.42), lineWidth: 0.85))
                }
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.bottom, 4)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, Theme.contentPadding)
        }
    }

    private var imEmptyConversationState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "message.and.waveform.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            let target = draftNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(target.isEmpty ? "新建短信会话" : "发送至 \(target)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
            Text(target.isEmpty ? "在顶部填写接收号码，通过下方输入框直接发送" : "暂无历史消息，发送后将在此处实时对话")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Unified bottom IM input bar for both existing threads and new conversations.
    private var imInputBar: some View {
        let textBinding = Binding<String>(
            get: { selectedThread != nil ? replyBody : (draftBody.isEmpty ? replyBody : draftBody) },
            set: { newValue in
                replyBody = newValue
                draftBody = newValue
            }
        )
        let currentText = textBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPhone = (selectedThread?.phone ?? draftNumber).trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = isLive && !busy && !currentText.isEmpty && !targetPhone.isEmpty
        let placeholder = targetPhone.isEmpty ? "输入短信内容…" : "发送给 \(targetPhone)…"

        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                TextField(placeholder, text: textBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary)
                    .onSubmit { submitIMMessage() }
                    .accessibilityLabel("短信内容")
                Text("\(textBinding.wrappedValue.count) 字")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                Button { submitIMMessage() } label: {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(canSend
                                             ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(Theme.inkMuted.opacity(0.55)))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送短信")
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(Theme.panelFill, in: CapsulePanelShape(maxRadius: 999))
            .overlay(CapsulePanelShape(maxRadius: 999)
                .strokeBorder(Theme.hairlineStrong, lineWidth: 0.85))
            .shadow(color: Theme.panelShadow, radius: 5, y: 2)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func submitIMMessage() {
        guard isLive, !busy else { return }
        let body = (selectedThread != nil ? replyBody : (draftBody.isEmpty ? replyBody : draftBody))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if let thread = activeThread {
            replyBody = body
            onSendReply(thread, body)
        } else {
            draftBody = body
            onSend()
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = activeThread?.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func bubble(_ message: SMSMessage) -> some View {
        let bubbleShape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return HStack(alignment: .bottom, spacing: 0) {
            if message.isSent { Spacer(minLength: 38) }
            VStack(alignment: message.isSent ? .trailing : .leading, spacing: 3) {
                Text(message.body)
                    .font(.system(size: 11.5, weight: .regular))
                    .lineSpacing(2.5)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        bubbleShape
                            .fill(message.isSent ? Color.accentColor : Color.white.opacity(0.95))
                    )
                    .overlay(
                        bubbleShape
                            .strokeBorder(message.isSent ? Color.accentColor.opacity(0.25) : Theme.hairlineStrong, lineWidth: 0.75)
                    )
                    .shadow(color: Color.black.opacity(message.isSent ? 0.08 : 0.04), radius: 3, y: 1)
                    .foregroundStyle(message.isSent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                HStack(spacing: 4) {
                    if message.isSent {
                        Text(message.id.hasPrefix("local-sent-") ? "发送中" : "已发送")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Text(shortTime(message.date))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            if !message.isSent { Spacer(minLength: 38) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.isSent ? "已发送" : "已接收")，\(message.body)")
    }

    // MARK: - Helpers

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.inkMuted)
            Text("没有可读取的短信")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Button("重新读取", action: onReload)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func initial(of phone: String) -> String {
        if let first = phone.first, first.isNumber { return String(first) }
        return String(phone.prefix(1))
    }

    /// `yyyy/MM/dd HH:mm:ss` → `HH:mm` for today, `MM/dd HH:mm` otherwise.
    private func shortTime(_ raw: String?) -> String {
        guard let raw, raw.count >= 16 else { return raw ?? "" }
        let parts = raw.split(separator: " ")
        guard parts.count == 2 else { return raw }
        let date = String(parts[0]), time = String(parts[1])
        let hhmm = String(time.prefix(5))
        if date == Self.dayFormatter.string(from: Date()) { return hhmm }
        let pieces = date.split(separator: "/")
        return pieces.count == 3 ? "\(pieces[1])/\(pieces[2]) \(hhmm)" : date
    }

    private static let syncTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()
}

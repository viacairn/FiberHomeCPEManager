import Foundation

/// While the SMS page is visible the app reads get_sms_data from the device at least once
/// every three seconds. Nothing is persisted: the conversation array is in-memory state that
/// is replaced by the device's reply.
public enum SMSRefreshPolicy {
    public static let interval = SessionRefreshPolicy.dataInterval

    public static func isDue(lastRead: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastRead) >= interval
    }
}

/// Coalesces requests that arrive during another SMS read or a send. A changed snapshot
/// count and a post-send refresh must still be read once the current operation finishes.
/// The owner keeps this value in memory and resets it when its connection is invalidated.
public struct SMSRefreshQueue: Sendable {
    public struct Request: Sendable, Equatable {
        public var quiet: Bool
        public var keepStatus: Bool
    }

    private var pending: Request?
    private var isReading = false

    public init() {}

    public mutating func request(quiet: Bool, keepStatus: Bool) {
        if let previous = pending {
            pending = Request(quiet: previous.quiet && quiet,
                              keepStatus: previous.keepStatus && keepStatus)
        } else {
            pending = Request(quiet: quiet, keepStatus: keepStatus)
        }
    }

    public mutating func beginNext(isSending: Bool) -> Request? {
        guard !isReading, !isSending, let request = pending else { return nil }
        pending = nil
        isReading = true
        return request
    }

    public mutating func finish() { isReading = false }
}

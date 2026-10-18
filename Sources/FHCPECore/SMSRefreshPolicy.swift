import Foundation

/// While the SMS page is visible the app reads get_sms_data from the device at least once
/// every five seconds. Nothing is persisted: the conversation array is in-memory state that
/// is replaced by the device's reply.
public enum SMSRefreshPolicy {
    public static let interval: TimeInterval = 5

    public static func isDue(lastRead: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastRead) >= interval
    }
}

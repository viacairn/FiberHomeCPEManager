import Foundation

/// The authenticated session outlives the popover. Protected samples stay current;
/// heartbeat checks authentication; refresh_timeout renews activity separately.
public enum SessionRefreshPolicy {
    public static let heartbeatInterval: TimeInterval = 30
    public static let dataInterval: TimeInterval = 3

    public static func sampleInterval(connected: Bool) -> Duration {
        .seconds(dataInterval)
    }

    public static func heartbeatIsDue(last: TimeInterval?, now: TimeInterval) -> Bool {
        guard let last else { return true }
        return now < last || now - last >= heartbeatInterval
    }
}

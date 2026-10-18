import Foundation

/// Reconciles a device-provided conversation list with optimistic sent bubbles.
///
/// The firmware's get_sms_data call can lag a just-sent message by a moment. The UI appends
/// the bubble immediately with an id prefixed local-sent-; this merge keeps that bubble
/// visible until the device reports a sent message with the same body in the same thread,
/// then drops the local copy. Without it, the conversation flickered: the bubble appeared,
/// a reload replaced the list, and the sent message vanished.
public enum SMSThreadMerge {
    public static func merge(threads: [SMSThread], keepingLocal local: [SMSThread]) -> [SMSThread] {
        var result = threads
        for localThread in local {
            let pending = localThread.messages.filter { $0.id.hasPrefix("local-sent-") }
            guard !pending.isEmpty else { continue }
            if let index = result.firstIndex(where: { $0.phone == localThread.phone }) {
                for message in pending where !result[index].messages.contains(where: {
                    $0.isSent && $0.body == message.body && isConfirmed(localDate: message.date, deviceDate: $0.date)
                }) {
                    result[index].messages.append(message)
                }
                result[index].messages.sort { $0.date < $1.date }
            } else {
                result.append(localThread)
            }
        }
        result.sort { ($0.lastMessage?.date ?? "") > ($1.lastMessage?.date ?? "") }
        return result
    }

    /// A device message only confirms a pending local bubble if its timestamp is at or after
    /// the local send time (allowing a 60-second clock skew between Mac and CPE). That stops
    /// an older sent message with the same body (e.g. a previous "流量查询") from prematurely
    /// swallowing a freshly sent bubble.
    private static func isConfirmed(localDate: String, deviceDate: String) -> Bool {
        let localNorm = localDate.replacingOccurrences(of: "-", with: "/")
        let deviceNorm = deviceDate.replacingOccurrences(of: "-", with: "/")
        if deviceNorm >= localNorm { return true }
        guard let localTime = parseDate(localNorm), let deviceTime = parseDate(deviceNorm) else {
            return true
        }
        return deviceTime.timeIntervalSince(localTime) >= -60
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

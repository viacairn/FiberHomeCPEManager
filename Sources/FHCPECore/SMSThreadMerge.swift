import Foundation

/// Reconciles device conversations with optimistic sent bubbles and local read status.
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
            if let index = result.firstIndex(where: { $0.phone == localThread.phone }) {
                // An earlier get_sms_data reply can arrive after the user opens a thread.
                // Keep those exact received messages read; a newly received message (or a
                // reused firmware node with different contents/time) still starts unread.
                let read = localThread.messages.filter { $0.isRead && !$0.isSent }
                result[index] = settingRead(true, for: read, in: result[index])
                for message in pending where !result[index].messages.contains(where: {
                    $0.isSent && $0.body == message.body && isConfirmed(localDate: message.date, deviceDate: $0.date)
                }) {
                    result[index].messages.append(message)
                }
                result[index].messages.sort { $0.date < $1.date }
            } else if !pending.isEmpty {
                result.append(localThread)
            }
        }
        result.sort { ($0.lastMessage?.date ?? "") > ($1.lastMessage?.date ?? "") }
        return result
    }

    /// Updates only the received messages included in one mark-read write. The same
    /// identity check also makes a late failure safe if a firmware node was reused.
    public static func settingRead(_ isRead: Bool, for messages: [SMSMessage], in thread: SMSThread) -> SMSThread {
        var result = thread
        for index in result.messages.indices where !result.messages[index].isSent {
            let candidate = result.messages[index]
            if messages.contains(where: {
                !$0.isSent && $0.id == candidate.id && $0.sender == candidate.sender
                    && $0.childnode == candidate.childnode && $0.date == candidate.date
                    && $0.body == candidate.body
            }) {
                result.messages[index].isRead = isRead
            }
        }
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

    private static let posixCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private static func parseDate(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { $0 == "/" || $0 == " " || $0 == ":" })
        guard parts.count == 6,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let hour = Int(parts[3]),
              let minute = Int(parts[4]),
              let second = Int(parts[5])
        else { return nil }
        return posixCalendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))
    }
}

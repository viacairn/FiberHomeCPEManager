import Testing
import Foundation
@testable import FHCPECore

/// Optimistic sent-message reconciliation.
struct SMSThreadMergeTests {
    private func message(_ body: String, sent: Bool = true, id: String = "d1", date: String = "2026/10/18 10:00:00") -> SMSMessage {
        SMSMessage(id: id, sender: "10010", body: body, date: date, isRead: true, isSent: sent)
    }

    @Test func localBubbleSurvivesAReloadBeforeTheDeviceCatchesUp() {
        let local = SMSThread(phone: "10010", messages: [
            message("older", sent: false, id: "r1", date: "2026/10/18 09:00:00"),
            message("流量查询", id: "local-sent-1", date: "2026/10/18 10:00:00")
        ])
        let device = SMSThread(phone: "10010", messages: [
            message("older", sent: false, id: "r1", date: "2026/10/18 09:00:00")
        ])
        let merged = SMSThreadMerge.merge(threads: [device], keepingLocal: [local])
        #expect(merged.count == 1)
        #expect(merged[0].messages.contains { $0.id == "local-sent-1" })
    }

    @Test func deviceConfirmationDropsTheLocalCopy() {
        let local = SMSThread(phone: "10010", messages: [
            message("流量查询", id: "local-sent-1", date: "2026/10/18 10:00:00")
        ])
        let device = SMSThread(phone: "10010", messages: [
            message("流量查询", id: "sent-9", date: "2026/10/18 10:00:03")
        ])
        let merged = SMSThreadMerge.merge(threads: [device], keepingLocal: [local])
        #expect(merged[0].messages.count == 1)
        #expect(merged[0].messages[0].id == "sent-9")
    }

    @Test func aThreadTheDeviceHasNotListedYetIsKept() {
        let local = SMSThread(phone: "10010", messages: [
            message("话费查询", id: "local-sent-2")
        ])
        let merged = SMSThreadMerge.merge(threads: [], keepingLocal: [local])
        #expect(merged.map(\.phone) == ["10010"])
    }

    @Test func threadsStayNewestFirst() {
        let a = SMSThread(phone: "10010", messages: [message("a", id: "local-sent-a", date: "2026/10/18 10:00:00")])
        let b = SMSThread(phone: "10086", messages: [message("b", sent: false, id: "r2", date: "2026/10/18 11:00:00")])
        let merged = SMSThreadMerge.merge(threads: [b], keepingLocal: [a])
        #expect(merged.map(\.phone) == ["10086", "10010"])
    }

    @Test func olderSentMessageDoesNotDropNewLocalCopy() {
        let local = SMSThread(phone: "10010", messages: [
            message("流量查询", id: "send-1", date: "2026/10/17 09:00:00"),
            message("流量查询", id: "local-sent-new", date: "2026/10/18 10:00:00")
        ])
        let device = SMSThread(phone: "10010", messages: [
            message("流量查询", id: "send-1", date: "2026/10/17 09:00:00")
        ])
        let merged = SMSThreadMerge.merge(threads: [device], keepingLocal: [local])
        #expect(merged[0].messages.count == 2)
        #expect(merged[0].messages.map(\.id) == ["send-1", "local-sent-new"])
    }
}

struct SMSReadMergeTests {
    private let phone = "+12025550123"

    private func received(_ id: String, body: String = "Test message", read: Bool,
                          date: String = "2026/10/20 10:00:00") -> SMSMessage {
        SMSMessage(id: id, sender: phone, body: body, date: date,
                   isRead: read, isSent: false, childnode: id)
    }

    @Test func staleDeviceReadDoesNotRestoreAnOpenedMessagesUnreadBadge() {
        let local = SMSThread(phone: phone, messages: [received("1", read: true)])
        let staleDevice = SMSThread(phone: phone, messages: [received("1", read: false)])

        let merged = SMSThreadMerge.merge(threads: [staleDevice], keepingLocal: [local])
        #expect(merged[0].unreadCount == 0)
    }

    @Test func readMergeLeavesNewlyReceivedMessagesUnread() {
        let local = SMSThread(phone: phone, messages: [received("1", read: true)])
        let device = SMSThread(phone: phone, messages: [
            received("1", read: false),
            received("2", body: "New test message", read: false, date: "2026/10/20 10:00:02")
        ])

        let merged = SMSThreadMerge.merge(threads: [device], keepingLocal: [local])
        #expect(merged[0].unreadCount == 1)
        #expect(merged[0].messages.filter { $0.isRead == false }.map(\.id) == ["2"])
    }

    @Test func reusedFirmwareNodeDoesNotInheritAnOlderMessagesReadState() {
        let local = SMSThread(phone: phone, messages: [received("1", body: "Old test message", read: true)])
        let device = SMSThread(phone: phone, messages: [
            received("1", body: "Replacement test message", read: false, date: "2026/10/20 11:00:00")
        ])

        let merged = SMSThreadMerge.merge(threads: [device], keepingLocal: [local])
        #expect(merged[0].unreadCount == 1)
    }

    @Test func readStateDoesNotCrossConversationBoundaries() {
        let local = SMSThread(phone: phone, messages: [received("1", read: true)])
        let otherPhone = "+12025550124"
        let device = SMSThread(phone: otherPhone, messages: [
            SMSMessage(id: "1", sender: otherPhone, body: "Test message", date: "2026/10/20 10:00:00",
                       isRead: false, isSent: false, childnode: "1")
        ])

        let merged = SMSThreadMerge.merge(threads: [device], keepingLocal: [local])
        #expect(merged.count == 1)
        #expect(merged[0].unreadCount == 1)
    }

    @Test func failedMarkReadRestoresOnlyMessagesIncludedInThatWrite() {
        let written = received("1", read: false)
        let current = SMSThread(phone: phone, messages: [
            received("1", read: true), received("2", read: true)
        ])

        let restored = SMSThreadMerge.settingRead(false, for: [written], in: current)
        #expect(restored.messages.filter { $0.isRead == false }.map(\.id) == ["1"])
    }

    @Test func lateMarkReadFailureDoesNotChangeAReusedDeviceNode() {
        let written = received("1", read: false)
        let current = SMSThread(phone: phone, messages: [
            received("1", body: "Replacement test message", read: true, date: "2026/10/20 11:00:00")
        ])

        let restored = SMSThreadMerge.settingRead(false, for: [written], in: current)
        #expect(restored.unreadCount == 0)
    }
}

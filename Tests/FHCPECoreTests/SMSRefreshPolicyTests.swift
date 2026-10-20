import Testing
import Foundation
@testable import FHCPECore

struct SMSRefreshPolicyTests {
    @Test func dueAfterThreeSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!SMSRefreshPolicy.isDue(lastRead: start, now: start.addingTimeInterval(2.9)))
        #expect(SMSRefreshPolicy.isDue(lastRead: start, now: start.addingTimeInterval(3)))
        #expect(SMSRefreshPolicy.isDue(lastRead: start, now: start.addingTimeInterval(4)))
    }
}

struct SMSRefreshQueueTests {
    @Test func requestDuringAReadRunsImmediatelyAfterThatReadFinishes() throws {
        var queue = SMSRefreshQueue()
        queue.request(quiet: true, keepStatus: true)
        let firstRead = queue.beginNext(isSending: false)
        _ = try #require(firstRead)

        // A send completion or changed device count must not be discarded merely because
        // an earlier get_sms_data request is still on the wire.
        queue.request(quiet: true, keepStatus: true)
        queue.request(quiet: true, keepStatus: true)
        let overlappingRead = queue.beginNext(isSending: false)
        #expect(overlappingRead == nil)

        queue.finish()
        let followUpRead = queue.beginNext(isSending: false)
        #expect(followUpRead != nil)
        queue.finish()
        let extraRead = queue.beginNext(isSending: false)
        #expect(extraRead == nil)
    }

    @Test func requestDuringSendWaitsUntilTheSendCompletes() {
        var queue = SMSRefreshQueue()
        queue.request(quiet: true, keepStatus: true)
        let readDuringSend = queue.beginNext(isSending: true)
        #expect(readDuringSend == nil)
        let readAfterSend = queue.beginNext(isSending: false)
        #expect(readAfterSend != nil)
    }

    @Test func mergedManualReloadKeepsItsProgressAndStatusReset() throws {
        var queue = SMSRefreshQueue()
        queue.request(quiet: true, keepStatus: true)
        queue.request(quiet: false, keepStatus: false)
        queue.request(quiet: true, keepStatus: true)

        let nextRead = queue.beginNext(isSending: false)
        let request = try #require(nextRead)
        #expect(request.quiet == false)
        #expect(request.keepStatus == false)
    }

    @Test func resettingForAnotherConnectionDropsQueuedReads() {
        var queue = SMSRefreshQueue()
        queue.request(quiet: true, keepStatus: true)
        _ = queue.beginNext(isSending: false)
        queue.request(quiet: true, keepStatus: true)

        queue = SMSRefreshQueue()
        let previousConnectionsRead = queue.beginNext(isSending: false)
        #expect(previousConnectionsRead == nil)
        queue.request(quiet: true, keepStatus: true)
        let newConnectionsRead = queue.beginNext(isSending: false)
        #expect(newConnectionsRead != nil)
    }
}

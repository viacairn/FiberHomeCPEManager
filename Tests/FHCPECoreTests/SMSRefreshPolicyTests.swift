import Testing
import Foundation
@testable import FHCPECore

struct SMSRefreshPolicyTests {
    @Test func dueAfterFiveSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!SMSRefreshPolicy.isDue(lastRead: start, now: start.addingTimeInterval(4.9)))
        #expect(SMSRefreshPolicy.isDue(lastRead: start, now: start.addingTimeInterval(5)))
        #expect(SMSRefreshPolicy.isDue(lastRead: start, now: start.addingTimeInterval(6)))
    }
}

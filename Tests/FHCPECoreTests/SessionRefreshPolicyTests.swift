import Foundation
import Testing
@testable import FHCPECore

struct SessionRefreshPolicyTests {
    @Test func heartbeatUsesMonotonicThirtySecondIntervals() {
        #expect(SessionRefreshPolicy.heartbeatIsDue(last: nil, now: 100))
        #expect(!SessionRefreshPolicy.heartbeatIsDue(last: 100, now: 129.999))
        #expect(SessionRefreshPolicy.heartbeatIsDue(last: 100, now: 130))
        #expect(SessionRefreshPolicy.heartbeatIsDue(last: 100, now: 700))
        #expect(SessionRefreshPolicy.heartbeatIsDue(last: 100, now: 99))
    }

    @Test func protectedSamplesContinueOnlineAndWhileRecovering() {
        #expect(SessionRefreshPolicy.sampleInterval(connected: true) == .seconds(3))
        #expect(SessionRefreshPolicy.sampleInterval(connected: false) == .seconds(3))
    }

    @Test func heartbeatRequiresAuthenticatedBodyRatherThanJustHTTP200() throws {
        try LocalTransport.validateHeartbeat(Data("1\n".utf8))
        #expect(throws: CPEError.authentication) { try LocalTransport.validateHeartbeat(Data("0\n".utf8)) }
        #expect(throws: CPEError.authentication) {
            try LocalTransport.validateHeartbeat(Data("<html>login</html>".utf8))
        }
        #expect(throws: CPEError.malformedResponse) { try LocalTransport.validateHeartbeat(Data("{}".utf8)) }
    }
}

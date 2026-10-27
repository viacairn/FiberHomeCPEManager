import Testing
@testable import FHCPEMUI

@MainActor
struct AppNoticeTests {
    @Test func noticesExpireAfterTenSeconds() {
        var now = 100.0
        let center = AppNoticeCenter(now: { now }, automaticDismissal: false)
        center.show("连接已断开", tone: .error)
        #expect(center.notices.count == 1)
        now = 109.999
        center.expire()
        #expect(center.notices.count == 1)
        now = 110
        center.expire()
        #expect(center.notices.isEmpty)
    }

    @Test func manualCloseDismissesOnlyTheSelectedNotice() throws {
        let center = AppNoticeCenter(automaticDismissal: false)
        center.show("已发送短信", tone: .success)
        center.show("连接已断开", tone: .error)
        let first = try #require(center.notices.first)
        center.dismiss(first.id)
        #expect(center.notices.map(\.message) == ["连接已断开"])
    }

    @Test func eachNoticeKeepsItsOwnDeadline() {
        var now = 0.0
        let center = AppNoticeCenter(now: { now }, automaticDismissal: false)
        center.show("第一条提醒", tone: .info)
        now = 8
        center.show("第二条提醒", tone: .success)
        now = 10
        center.expire()
        #expect(center.notices.map(\.message) == ["第二条提醒"])
        now = 18
        center.expire()
        #expect(center.notices.isEmpty)
    }

    @Test func repeatedNoticeRefreshesInsteadOfStacking() throws {
        var now = 0.0
        let center = AppNoticeCenter(now: { now }, automaticDismissal: false)
        center.show("已发送短信", tone: .success)
        let old = try #require(center.notices.first)
        now = 8
        center.show("已发送短信", tone: .success)
        #expect(center.notices.count == 1)
        center.dismiss(old.id)
        #expect(center.notices.count == 1)
        now = 10
        center.expire()
        #expect(center.notices.count == 1)
        now = 18
        center.expire()
        #expect(center.notices.isEmpty)
    }

    @Test func emptyFeedbackDoesNotCreateABubble() {
        let center = AppNoticeCenter(automaticDismissal: false)
        center.show(" \n ", tone: .info)
        #expect(center.notices.isEmpty)
    }

    @Test func automaticDismissalRunsWithoutAnyViewBeingMounted() async throws {
        let center = AppNoticeCenter(lifetime: 0.02)
        center.show("已保存设置", tone: .success)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !center.notices.isEmpty, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(10))
        }
        #expect(center.notices.isEmpty)
    }

    @Test func successAndFailureAreDeliveredImmediatelyWithTheirTone() {
        let model = ShellModel()
        model.notices.show("操作失败", tone: .error)
        model.notices.show("已保存设置", tone: .success)
        #expect(model.notices.notices.map(\.tone) == [.error, .success])
    }

    @Test func readingStateDoesNotClearAnOperationNotice() {
        let model = ShellModel()
        model.notices.show("已发送短信", tone: .success)
        model.smsBusy = false
        #expect(model.notices.notices.map(\.message) == ["已发送短信"])
    }
}

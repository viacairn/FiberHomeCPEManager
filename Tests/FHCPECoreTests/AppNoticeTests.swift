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
        try await Task.sleep(for: .milliseconds(100))
        #expect(center.notices.isEmpty)
    }

    @Test func anImmediateRefreshDoesNotLoseTheSendConfirmation() {
        let model = ShellModel()
        model.smsStatus = "已发送短信"
        model.smsStatusIsError = false
        model.smsStatus = nil
        model.notices.deliverStatuses()
        #expect(model.notices.notices.map(\.message) == ["已发送短信"])
        #expect(model.notices.notices.first?.tone == .success)
    }

    @Test func feedbackKeepsTheToneAssignedBeforeItsFieldIsCleared() {
        let model = ShellModel()
        model.settingsStatus = "操作失败"
        model.settingsStatusIsError = true
        model.settingsStatus = nil
        model.settingsStatusIsError = false
        model.settingsStatus = "已保存设置"
        model.notices.deliverStatuses()
        #expect(model.notices.notices.map(\.tone) == [.error, .success])
    }

    @Test func unchangedPollingStatusDoesNotReappearAfterManualClose() throws {
        let model = ShellModel()
        model.smsStatus = "短信读取失败"
        model.smsStatusIsError = true
        model.notices.deliverStatuses()
        model.notices.dismiss(try #require(model.notices.notices.first).id)
        model.smsStatus = "短信读取失败"
        model.notices.deliverStatuses()
        #expect(model.notices.notices.isEmpty)
    }

    @Test func unfinishedUplinkSwitchIsInformational() {
        let model = ShellModel()
        model.settingsStatus = "正在切换到蜂窝上行…"
        model.settingsStatusIsError = false
        model.settingsStatus = "切换中连接中断，正在重连…"
        model.notices.deliverStatuses()
        #expect(model.notices.notices.map(\.tone) == [.info, .info])
    }

    @Test func savedConnectionReadFailureUsesErrorFeedback() {
        let model = ShellModel()
        model.statusMessage = "无法读取已保存的连接，请重新输入密码。"
        model.notices.deliverStatuses()
        #expect(model.notices.notices.first?.tone == .error)
    }
}

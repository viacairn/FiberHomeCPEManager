import Testing
import Foundation
@testable import FHCPECore

/// Firmware login-rejection mapping.
///
/// `DO_WEB_LOGIN` does not return a bare failure: it returns a numeric reason. The app used
/// to collapse every non-zero code into one message ("登录失败或会话已失效"), which hid the
/// difference between a typo, a one-minute lockout and a disabled admin account. Codes and
/// wording come from the device's own `login_res.js`.
struct LoginErrorTests {
    @Test func lockoutIsNotReportedAsAWrongPassword() {
        let error = LG6851Adapter.loginError(forCode: "2")
        guard case .loginRejected(let message) = error else {
            Issue.record("expected loginRejected, got \(error)")
            return
        }
        #expect(message.contains("1 分钟"))
        #expect(!message.contains("密码错误"))
    }

    @Test func everyKnownCodeHasItsOwnMessage() {
        let messages = ["1", "2", "3", "4", "5"].map { code -> String in
            guard case .loginRejected(let message) = LG6851Adapter.loginError(forCode: code) else { return "" }
            return message
        }
        #expect(Set(messages).count == 5, "codes must not collapse into one message")
        #expect(messages.allSatisfy { !$0.isEmpty })
    }

    @Test func alreadyLoggedInSaysSo() {
        guard case .loginRejected(let message) = LG6851Adapter.loginError(forCode: "1") else {
            Issue.record("wrong case"); return
        }
        #expect(message.contains("其他设备"))
    }

    @Test func wrongCredentialsSaysSo() {
        guard case .loginRejected(let message) = LG6851Adapter.loginError(forCode: "4") else {
            Issue.record("wrong case"); return
        }
        #expect(message.contains("用户名或密码错误"))
    }

    @Test func disabledAdminSaysSo() {
        guard case .loginRejected(let message) = LG6851Adapter.loginError(forCode: "3") else {
            Issue.record("wrong case"); return
        }
        #expect(message.contains("禁用"))
    }

    /// An unknown code still carries the number, so a bug report can identify it.
    @Test func unknownCodeKeepsTheNumber() {
        guard case .loginRejected(let message) = LG6851Adapter.loginError(forCode: "99") else {
            Issue.record("wrong case"); return
        }
        #expect(message.contains("99"))
    }
}

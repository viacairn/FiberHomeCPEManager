import Testing
import Foundation
@testable import FHCPECore

/// Input-method conversion must be caught before a login request consumes an attempt.
struct PasswordInputTests {
    @Test func asciiPasswordIsAccepted() {
        #expect(PasswordInput.issue(in: "Test12345,") == nil)
    }

    @Test func chineseFullWidthCommaIsFlagged() {
        let issue = PasswordInput.issue(in: "Test12345，")
        guard case .fullWidth(let character) = issue else {
            Issue.record("expected fullWidth, got (String(describing: issue))")
            return
        }
        #expect(character == "，")
    }

    @Test func fullWidthCharactersCanBeConvertedExplicitly() {
        #expect(PasswordInput.halfWidth("Test12345，") == "Test12345,")
        #expect(PasswordInput.halfWidth("！ＡＢＣ") == "!ABC")
    }

    @Test func surroundingWhitespaceIsFlagged() {
        #expect(PasswordInput.issue(in: " Test12345,") == .surroundingWhitespace)
        #expect(PasswordInput.issue(in: "Test12345, ") == .surroundingWhitespace)
    }

    @Test func emptyIsDistinct() {
        #expect(PasswordInput.issue(in: "") == .empty)
    }

    @Test func messageNamesTheFullWidthCharacter() {
        guard case .fullWidth = PasswordInput.issue(in: "Test12345，") else {
            Issue.record("expected fullWidth")
            return
        }
        #expect(PasswordInputIssue.fullWidth("，").message.contains("全角"))
        #expect(PasswordInputIssue.fullWidth("，").message.contains("半角"))
    }
}

import Testing
import Foundation
@testable import FHCPECore

/// Login entry normalizes characters; only an empty submitted password is rejected.
struct PasswordInputTests {
    @Test func asciiPasswordIsAccepted() {
        #expect(PasswordInput.issue(in: "Test12345,") == nil)
    }

    @Test func fullWidthCharactersAreNormalizedForLogin() {
        #expect(PasswordInput.halfWidth("Test12345，") == "Test12345,")
        #expect(PasswordInput.halfWidth("！ＡＢＣ") == "!ABC")
    }

    @Test func surroundingWhitespaceDoesNotProduceAnError() {
        #expect(PasswordInput.issue(in: " Test12345,") == nil)
        #expect(PasswordInput.issue(in: "Test12345, ") == nil)
    }

    @Test func emptyIsDistinct() {
        #expect(PasswordInput.issue(in: "") == .empty)
    }

}

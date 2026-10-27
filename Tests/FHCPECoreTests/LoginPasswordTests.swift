import AppKit
import SwiftUI
import Testing
@testable import FHCPEMUI

@MainActor
@Suite(.serialized)
struct LoginPasswordTests {
    private func withPasswordField(password: Binding<String>, onConnect: @escaping () -> Void = {},
                                   _ run: (NSTextField, NSTextView) throws -> Void) throws {
        _ = NSApplication.shared
        let page = ConnectPage(address: .constant("192.168.8.1"), username: .constant("admin"),
                               password: password, savePassword: .constant(false), busy: false,
                               error: nil, onConnect: onConnect, onDetectGateway: {})
        let host = NSHostingView(rootView: page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.makeFirstResponder(nil); window.close() }
        host.layoutSubtreeIfNeeded()
        func findField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "请输入管理员密码" {
                return field
            }
            return view.subviews.lazy.compactMap(findField).first
        }
        let field = try #require(findField(host))
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        try run(field, editor)
    }

    @Test func pastedFullWidthCharactersBecomeHalfWidthBeforeLogin() throws {
        var password = "Original123,"
        var submittedPasswords: [String] = []
        try withPasswordField(password: Binding(get: { password }, set: { password = $0 }),
                              onConnect: { submittedPasswords.append(password) }) { field, editor in
            editor.selectAll(nil)
            editor.insertText("Ｎｅｗ１２３，", replacementRange: editor.selectedRange())
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            #expect(password == "New123,")
            field.sendAction(field.action, to: field.target)
            #expect(submittedPasswords == ["New123,"])
        }
    }

    @Test func submissionNormalizesAnInitiallySuppliedFullWidthPassword() throws {
        var password = "　Ａｄｍｉｎ１２３！　"
        var submittedPassword: String?
        try withPasswordField(password: Binding(get: { password }, set: { password = $0 }),
                              onConnect: { submittedPassword = password }) { field, _ in
            field.sendAction(field.action, to: field.target)
            #expect(submittedPassword == "Admin123!")
            #expect(password == "Admin123!")
        }
    }

    @Test(arguments: ["", " \t\n", "　"]) func emptyPasswordDoesNotStartLogin(_ input: String) throws {
        var password = input
        var connections = 0
        try withPasswordField(password: Binding(get: { password }, set: { password = $0 }),
                              onConnect: { connections += 1 }) { field, _ in
            field.sendAction(field.action, to: field.target)
            #expect(connections == 0)
        }
    }
}

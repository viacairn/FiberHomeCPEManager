import AppKit
import SwiftUI
import Testing
@testable import FHCPEMUI

@MainActor
@Suite(.serialized)
struct LoginPasswordTests {
    private func withEditor(secure: Bool, prepare: (NSTextView) -> Void = { _ in },
                            _ run: (LoginPasswordControl, NSTextView) throws -> Void) rethrows {
        _ = NSApplication.shared
        let control = LoginPasswordControl(frame: NSRect(x: 10, y: 10, width: 260, height: 20))
        control.configure(text: "Test12345,", secure: secure, focused: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(control)
        if let editor = window.fieldEditor(true, for: control.field) as? NSTextView { prepare(editor) }
        window.makeFirstResponder(control.field)
        defer { window.makeFirstResponder(nil); window.close() }
        guard let editor = control.field.currentEditor() as? NSTextView else {
            Issue.record("password field did not acquire its native editor")
            return
        }
        try run(control, editor)
    }

    @Test(arguments: [true, false])
    func passwordEditorRequestsRomanKeyboard(secure: Bool) {
        withEditor(secure: secure) { _, editor in
            #expect(editor.allowedInputSourceLocales == [NSAllRomanInputSourcesLocaleIdentifier])
        }
    }

    @Test(arguments: [true, false])
    func fullWidthTypingIsRejectedWithoutChangingThePassword(secure: Bool) {
        withEditor(secure: secure) { control, editor in
            var changes: [String] = []
            var rejections = 0
            control.onChange = { changes.append($0) }
            control.onRejectedInput = { rejections += 1 }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText("，", replacementRange: editor.selectedRange())
            #expect(editor.string == "Test12345,")
            #expect(control.field.stringValue == "Test12345,")
            #expect(changes.isEmpty)
            #expect(rejections == 1)
        }
    }

    @Test(arguments: [true, false])
    func pasteRejectsTheWholeInvalidReplacement(secure: Bool) {
        withEditor(secure: secure) { control, editor in
            let selection = NSRange(location: 0, length: editor.string.utf16.count)
            editor.setSelectedRange(selection)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("NewPassword１２３，", forType: .string)
            _ = editor.readSelection(from: pasteboard, type: .string)
            #expect(editor.string == "Test12345,")
            #expect(control.field.stringValue == "Test12345,")
            #expect(editor.selectedRange() == selection)
        }
    }

    @Test(arguments: [true, false])
    func asciiPunctuationAndDeletionRemainEditable(secure: Bool) {
        withEditor(secure: secure) { control, editor in
            var value = ""
            control.onChange = { value = $0 }
            editor.selectAll(nil)
            editor.insertText("Az09,!@#$%^&*()_+-=[]{};:'\"\\|<>./?`~", replacementRange: editor.selectedRange())
            #expect(value == "Az09,!@#$%^&*()_+-=[]{};:'\"\\|<>./?`~")
            editor.selectAll(nil)
            editor.deleteBackward(nil)
            #expect(value.isEmpty)
            #expect(control.field.stringValue.isEmpty)
        }
    }

    @Test func revealingPasswordKeepsItsValueSelectionAndKeyboardRestriction() {
        withEditor(secure: true) { control, editor in
            let selection = NSRange(location: 3, length: 4)
            editor.setSelectedRange(selection)
            control.configure(text: "Test12345,", secure: false, focused: true)
            guard let revealedEditor = control.field.currentEditor() as? NSTextView else {
                Issue.record("revealed password lost keyboard focus")
                return
            }
            #expect(!(control.field is NSSecureTextField))
            #expect(revealedEditor.string == "Test12345,")
            #expect(revealedEditor.selectedRange() == selection)
            #expect(revealedEditor.allowedInputSourceLocales == [NSAllRomanInputSourcesLocaleIdentifier])
            control.configure(text: "Test12345,", secure: true, focused: true)
            #expect(control.field is NSSecureTextField)
            #expect(control.field.currentEditor()?.string == "Test12345,")
        }
    }

    @Test(arguments: [true, false])
    func clearingPasswordAlsoClearsTheActiveEditor(secure: Bool) {
        withEditor(secure: secure) { control, editor in
            control.configure(text: "", secure: secure, focused: true)
            #expect(control.field.stringValue.isEmpty)
            #expect(editor.string.isEmpty)
        }
    }

    @Test func leavingPasswordRestoresTheSharedEditorInputSources() {
        withEditor(secure: false, prepare: { editor in
            editor.allowedInputSourceLocales = ["en"]
            editor.isAutomaticTextReplacementEnabled = true
            editor.isAutomaticQuoteSubstitutionEnabled = true
            editor.isAutomaticDashSubstitutionEnabled = true
            editor.isAutomaticSpellingCorrectionEnabled = true
        }) { control, editor in
            #expect(!editor.isAutomaticTextReplacementEnabled)
            control.window?.makeFirstResponder(nil)
            // NSTextFieldCell resets the editor locale to nil before our preparation
            // hook runs. Restore that baseline rather than leaking the Roman override.
            #expect(editor.allowedInputSourceLocales == nil)
            #expect(editor.isAutomaticTextReplacementEnabled)
            #expect(editor.isAutomaticQuoteSubstitutionEnabled)
            #expect(editor.isAutomaticDashSubstitutionEnabled)
            #expect(editor.isAutomaticSpellingCorrectionEnabled)
            let next = NSTextField(frame: NSRect(x: 10, y: 35, width: 260, height: 20))
            control.window?.contentView?.addSubview(next)
            control.window?.makeFirstResponder(next)
            #expect(next.currentEditor() === editor)
        }
    }

    @Test func rejectedInputCannotSubmitThePreviousPassword() throws {
        _ = NSApplication.shared
        var password = "Test12345,"
        var connections = 0
        let page = ConnectPage(address: .constant("192.0.2.1"), username: .constant("admin"),
                               password: Binding(get: { password }, set: { password = $0 }),
                               savePassword: .constant(false), busy: false, error: nil,
                               onConnect: { connections += 1 }, onDetectGateway: {})
        let host = NSHostingView(rootView: page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 606),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.makeFirstResponder(nil); window.close() }
        host.layoutSubtreeIfNeeded()
        func findControl(_ view: NSView) -> LoginPasswordControl? {
            if let control = view as? LoginPasswordControl { return control }
            return view.subviews.lazy.compactMap(findControl).first
        }
        let control = try #require(findControl(host))
        window.makeFirstResponder(control.field)
        let editor = try #require(control.field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Invalid，", replacementRange: editor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        control.field.sendAction(control.field.action, to: control.field.target)
        #expect(connections == 0)
        #expect(password == "Test12345,")
        editor.selectAll(nil)
        editor.insertText("CorrectPassword,", replacementRange: editor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        control.field.sendAction(control.field.action, to: control.field.target)
        #expect(connections == 1)
        #expect(password == "CorrectPassword,")
    }
}

import AppKit
import SwiftUI
import FHCPECore

/// The login password needs an input-source restriction, which SwiftUI's TextField
/// does not expose on macOS. Keep the native bridge inside the existing capsule.
struct LoginPasswordField: NSViewRepresentable {
    @Binding var text: String
    let secure: Bool
    @FocusState.Binding var focus: ConnectionField?
    let onSubmit: () -> Void
    let onRejectedInput: () -> Void
    let onAcceptedInput: () -> Void

    func makeNSView(context: Context) -> LoginPasswordControl {
        LoginPasswordControl()
    }

    func updateNSView(_ view: LoginPasswordControl, context: Context) {
        view.onChange = { text = $0; onAcceptedInput() }
        view.onRejectedInput = onRejectedInput
        view.onSubmit = onSubmit
        view.onFocusChange = { focused in
            if focused, focus != .password { focus = .password }
            else if !focused, focus == .password { focus = nil }
        }
        view.configure(text: text, secure: secure, focused: focus == .password)
    }

    static func dismantleNSView(_ view: LoginPasswordControl, coordinator: ()) {
        view.restoreInputSources()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LoginPasswordControl,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: 16)
    }
}

/// AppKit's partial-string validation rejects an entire edit before it reaches either
/// the field editor or the password binding, including replacement via paste.
private final class PasswordEntryFormatter: Formatter, @unchecked Sendable {
    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                 for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialString: String,
                                      newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                      errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        !partialString.unicodeScalars.contains(where: PasswordInput.isFullWidth)
    }
}

private final class RomanPasswordCell: NSTextFieldCell {
    var prepareEditor: (NSTextView) -> Void = { _ in }
    var finishEditing: () -> Void = {}
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let editor = editor as? NSTextView { prepareEditor(editor) }
        return editor
    }
    override func endEditing(_ textObj: NSText) {
        finishEditing()
        super.endEditing(textObj)
    }
}

private final class RomanSecurePasswordCell: NSSecureTextFieldCell {
    var prepareEditor: (NSTextView) -> Void = { _ in }
    var finishEditing: () -> Void = {}
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let editor = editor as? NSTextView { prepareEditor(editor) }
        return editor
    }
    override func endEditing(_ textObj: NSText) {
        finishEditing()
        super.endEditing(textObj)
    }
}

@MainActor
final class LoginPasswordControl: NSView, NSTextFieldDelegate {
    private(set) var field: NSTextField = NSSecureTextField()
    var onChange: (String) -> Void = { _ in }
    var onRejectedInput: () -> Void = {}
    var onSubmit: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    private weak var restrictedEditor: NSTextView?
    private var previousEditorSettings: EditorSettings?
    private var changingMode = false
    private var requestedFocus = false

    private struct EditorSettings {
        let inputSources: [String]?
        let textReplacement: Bool
        let quotes: Bool
        let dashes: Bool
        let spelling: Bool
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installField()
    }

    required init?(coder: NSCoder) { nil }

    private func installField() {
        if field is NSSecureTextField {
            let cell = RomanSecurePasswordCell(textCell: "")
            cell.prepareEditor = { [weak self] in self?.restrictInputSources(in: $0) }
            cell.finishEditing = { [weak self] in self?.finishEditing() }
            field.cell = cell
        } else {
            let cell = RomanPasswordCell(textCell: "")
            cell.prepareEditor = { [weak self] in self?.restrictInputSources(in: $0) }
            cell.finishEditing = { [weak self] in self?.finishEditing() }
            field.cell = cell
        }
        field.isBordered = false
        field.isBezeled = false
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11.5)
        field.placeholderString = "请输入管理员密码"
        field.contentType = .password
        field.setAccessibilityLabel("密码")
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = false
        field.formatter = PasswordEntryFormatter()
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(text: String, secure: Bool, focused: Bool) {
        requestedFocus = focused
        if (field is NSSecureTextField) != secure {
            let editor = field.currentEditor() as? NSTextView
            let selection = editor?.selectedRange()
            changingMode = true
            if editor != nil { window?.makeFirstResponder(nil) }
            restoreInputSources()
            field.removeFromSuperview()
            field = secure ? NSSecureTextField() : NSTextField()
            installField()
            field.stringValue = text
            layoutSubtreeIfNeeded()
            if editor != nil {
                window?.makeFirstResponder(field)
                if let selection, let nextEditor = field.currentEditor() as? NSTextView {
                    let length = text.utf16.count
                    let location = min(selection.location, length)
                    nextEditor.setSelectedRange(NSRange(location: location,
                        length: min(selection.length, length - location)))
                }
            }
            changingMode = false
        } else if field.stringValue != text {
            field.stringValue = text
        }
        // SwiftUI may request focus before this view has joined its window. Defer only
        // the responder change; edits and password validation stay synchronous.
        DispatchQueue.main.async { [weak self] in self?.applyRequestedFocus() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { restoreInputSources() }
    }

    private func applyRequestedFocus() {
        guard let window else { return }
        if requestedFocus, field.currentEditor() == nil {
            window.makeFirstResponder(field)
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if !changingMode { onFocusChange(true) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditing()
    }

    private func finishEditing() {
        restoreInputSources()
        if !changingMode {
            requestedFocus = false
            onFocusChange(false)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange(field.stringValue)
    }

    func control(_ control: NSControl, didFailToValidatePartialString string: String,
                 errorDescription error: String?) {
        onRejectedInput()
    }

    func restoreInputSources() {
        if let editor = restrictedEditor, let previous = previousEditorSettings {
            editor.allowedInputSourceLocales = previous.inputSources
            editor.isAutomaticTextReplacementEnabled = previous.textReplacement
            editor.isAutomaticQuoteSubstitutionEnabled = previous.quotes
            editor.isAutomaticDashSubstitutionEnabled = previous.dashes
            editor.isAutomaticSpellingCorrectionEnabled = previous.spelling
        }
        restrictedEditor = nil
        previousEditorSettings = nil
    }

    private func restrictInputSources(in editor: NSTextView) {
        guard restrictedEditor !== editor else { return }
        restoreInputSources()
        restrictedEditor = editor
        previousEditorSettings = EditorSettings(inputSources: editor.allowedInputSourceLocales,
            textReplacement: editor.isAutomaticTextReplacementEnabled,
            quotes: editor.isAutomaticQuoteSubstitutionEnabled,
            dashes: editor.isAutomaticDashSubstitutionEnabled,
            spelling: editor.isAutomaticSpellingCorrectionEnabled)
        editor.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        if !changingMode { requestedFocus = true }
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, self.field.currentEditor() === editor else { return }
            self.onFocusChange(true)
        }
    }

    @objc private func submit() { onSubmit() }
}

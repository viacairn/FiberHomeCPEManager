import AppKit
import SwiftUI

/// SwiftUI's horizontal ScrollView reserves a legacy scroller row when macOS is set
/// to always show scrollbars, even inside a 16 pt title. Keep only this overflow case
/// native so its viewport stays the same size under either system preference.
struct OverflowPhoneTitle: NSViewRepresentable {
    let phone: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let label = NSTextField(labelWithString: phone)
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        scroll.documentView = label
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let label = scroll.documentView as? NSTextField else { return }
        let changed = label.stringValue != phone
        label.stringValue = phone
        label.frame = NSRect(x: 0, y: 0, width: ceil(label.intrinsicContentSize.width), height: 16)
        label.setAccessibilityLabel(phone)
        if changed {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? 220, height: 16)
    }
}

import AppKit
import SwiftUI

/// Applies the page scroll policy without changing the native popover geometry.
/// AppKit's full-size content extends the background beyond the fixed SwiftUI canvas;
/// that breathing room is part of the panel design, not scrollable page content.
@MainActor
public final class PopoverHostingController<Content: View>: NSHostingController<Content> {
    public init(rootView: Content, designSize: NSSize) {
        super.init(rootView: rootView)
        sizingOptions = []
        // The shell owns all page insets. Disable only SwiftUI's inherited arrow
        // safe area; AppKit still keeps its full background extension and window size.
        safeAreaRegions = []
        view.frame.size = designSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:designSize:)") }

    public override func viewDidLayout() {
        super.viewDidLayout()
        configureScrollViews(in: view)
    }

    private func configureScrollViews(in view: NSView) {
        if let scroll = view as? NSScrollView, !(scroll.documentView is NSTextView) {
            // These pages are vertical. Text fields keep their own native field editor
            // behavior; only page scroll views use overlay indicators without a gutter.
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
            if scroll.horizontalScrollElasticity != .none { scroll.horizontalScrollElasticity = .none }
        }
        view.subviews.forEach(configureScrollViews)
    }
}

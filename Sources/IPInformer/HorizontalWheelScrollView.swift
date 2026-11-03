import AppKit
import SwiftUI

private final class WheelToHorizontalScrollView: NSScrollView {
    var onOffsetChange: ((CGFloat) -> Void)?

    var maximumOffset: CGFloat {
        max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
    }

    func setHorizontalOffset(_ offset: CGFloat, notify: Bool = false) {
        let clamped = min(max(offset, 0), maximumOffset)
        guard abs(contentView.bounds.minX - clamped) > 0.1 else { return }
        contentView.scroll(to: NSPoint(x: clamped, y: 0))
        reflectScrolledClipView(contentView)
        if notify { onOffsetChange?(clamped) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard maximumOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
            setHorizontalOffset(contentView.bounds.minX - event.scrollingDeltaY * multiplier, notify: true)
        } else {
            super.scrollWheel(with: event)
            onOffsetChange?(contentView.bounds.minX)
        }
    }
}

struct HorizontalWheelScrollView<Content: View>: NSViewRepresentable {
    let contentWidth: CGFloat
    @Binding var offset: CGFloat
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = WheelToHorizontalScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        let host = NSHostingView(rootView: content())
        host.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 36)
        scrollView.documentView = host
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let scrollView = nsView as? WheelToHorizontalScrollView,
              let host = scrollView.documentView as? NSHostingView<Content> else { return }
        host.rootView = content()
        host.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 36)
        let offsetBinding = _offset
        scrollView.onOffsetChange = { offsetBinding.wrappedValue = $0 }
        scrollView.setHorizontalOffset(offset)
    }
}

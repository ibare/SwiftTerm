#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@Suite("Marked text overlay")
struct MarkedTextOverlayTests {
    @MainActor
    private func overlay(afterMarking text: String, feed: String = "") -> (TerminalView, DictationOverlayTextView?) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        if !feed.isEmpty {
            view.feed(text: feed)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        view.setMarkedText(text,
                           selectedRange: NSRange(location: text.utf16.count, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let overlay = view.subviews.compactMap { $0 as? DictationOverlayTextView }.first
        return (view, overlay)
    }

    @MainActor
    @Test func backgroundCoversOnlyTheComposedCharacter() {
        let (view, overlay) = overlay(afterMarking: "한")
        #expect(overlay != nil)
        guard let overlay else { return }

        let rects = overlay.backgroundRects()
        #expect(rects.count == 1)
        // One wide character spans two cells; the painted area must not reach
        // across the row, where it would hide the terminal contents.
        #expect((rects.first?.width ?? .infinity) < 4 * view.cellDimension.width)
        #expect((rects.first?.width ?? .infinity) < overlay.bounds.width / 2)
    }

    @MainActor
    @Test func backgroundStaysNarrowWhenTheCaretIsMidRow() {
        let (view, overlay) = overlay(afterMarking: "한", feed: "prompt text> ")
        guard let overlay else {
            Issue.record("The overlay was not installed")
            return
        }

        let rects = overlay.backgroundRects()
        #expect(rects.count == 1)
        #expect((rects.first?.width ?? .infinity) < 4 * view.cellDimension.width)
    }
}
#endif

#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
private final class BellCountingDelegate: LocalProcessTerminalViewDelegate {
    var bells = 0

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
    func bell(source: TerminalView) { bells += 1 }
}

@Suite("LocalProcessTerminalView bell")
struct LocalProcessTerminalViewBellTests {
    /// The bell is parsed off the main thread and delivered through a
    /// main-queue drain; yield until it lands.
    @MainActor
    private func bells(_ delegate: BellCountingDelegate, atLeast expected: Int,
                       within duration: Duration = .seconds(2)) async -> Int {
        let deadline = ContinuousClock.now + duration
        while delegate.bells < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return delegate.bells
    }

    @MainActor
    @Test func bellIsForwardedToTheProcessDelegate() async {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let delegate = BellCountingDelegate()
        view.processDelegate = delegate

        view.feed(text: "\u{07}")
        #expect(await bells(delegate, atLeast: 1) == 1)
    }

    @MainActor
    @Test func disabledBellStyleIsNotForwarded() async {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let delegate = BellCountingDelegate()
        view.processDelegate = delegate
        view.bellStyle = .none

        view.feed(text: "\u{07}")
        #expect(await bells(delegate, atLeast: 1, within: .milliseconds(300)) == 0)
    }
}
#endif

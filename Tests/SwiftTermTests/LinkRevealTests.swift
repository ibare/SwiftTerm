//
//  LinkRevealTests.swift
//
//  Trailing particles on implicit links, and the row scan used to reveal
//  every visible link while Command is held.
//

import Foundation
import Testing

@testable import SwiftTerm

final class LinkRevealTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
    }

    private func makeTerminal(_ input: String, cols: Int = 80, rows: Int = 3) -> Terminal {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows))
        terminal.feed(text: input)
        return terminal
    }

    private func link(in input: String, at col: Int) -> String? {
        makeTerminal(input).link(at: .buffer(Position(col: col, row: 0)), mode: .explicitAndImplicit)
    }

    @Test func testAttachedParticleIsNotPartOfTheLink() {
        // Korean attaches particles to the preceding word; `\w` would swallow them.
        #expect(link(in: "docs/bugs/BUG_LOG.md에 적고", at: 2) == "docs/bugs/BUG_LOG.md")
        #expect(link(in: "see src/app.ts가 바뀌었다", at: 6) == "src/app.ts")
        #expect(link(in: "at src/app.ts:12의 줄", at: 5) == "src/app.ts:12")
    }

    @Test func testNonASCIIFileNamesAreKept() {
        // The run follows `/` or another non-ASCII character, so it is a name, not a particle.
        #expect(link(in: "open ./문서/노트.md now", at: 7) == "./문서/노트.md")
        #expect(link(in: "open docs/노트.md에서 봐", at: 7) == "docs/노트.md")
    }

    @Test func testImplicitLinkRangesCoverEveryVisibleLink() {
        let terminal = makeTerminal("see docs/a.md와 https://example.com here")
        let ranges = terminal.implicitLinkRanges(inRows: 0..<3)
        #expect(ranges.contains(.init(row: 0, range: 4..<13)))    // docs/a.md, particle excluded
        #expect(ranges.contains(.init(row: 0, range: 16..<35)))   // https://example.com
        #expect(ranges.count == 2)
    }

    @Test func testImplicitLinkRangesSkipRowsOutsideTheWindow() {
        let terminal = makeTerminal("docs/a.md\r\nplain\r\ndocs/b.md")
        let ranges = terminal.implicitLinkRanges(inRows: 1..<3)
        #expect(ranges == [.init(row: 2, range: 0..<9)])
    }
}

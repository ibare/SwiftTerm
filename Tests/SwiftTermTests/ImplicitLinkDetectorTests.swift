//
//  ImplicitLinkDetectorTests.swift
//
//  A host-supplied implicit link detector replaces the built-in pattern for both the
//  lookup under the pointer and the row scan that reveals every visible link.
//

import Foundation
import Testing

@testable import SwiftTerm

final class ImplicitLinkDetectorTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
    }

    private func makeTerminal(_ input: String, detector: Terminal.ImplicitLinkDetector?) -> Terminal {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 3))
        terminal.implicitLinkDetector = detector
        terminal.feed(text: input)
        return terminal
    }

    /// Links every occurrence of `word`.
    private static func linking(_ word: String) -> Terminal.ImplicitLinkDetector {
        return { text in
            var ranges: [Range<String.Index>] = []
            var start = text.startIndex
            while let found = text.range(of: word, range: start..<text.endIndex) {
                ranges.append(found)
                start = found.upperBound
            }
            return ranges
        }
    }

    @Test func testDetectorReplacesTheBuiltInPatternForLookup() {
        let terminal = makeTerminal("open docs/a.md or target", detector: Self.linking("target"))
        #expect(terminal.link(at: .buffer(Position(col: 19, row: 0)), mode: .explicitAndImplicit) == "target")
        // The built-in pattern would have found docs/a.md; the detector did not.
        #expect(terminal.link(at: .buffer(Position(col: 6, row: 0)), mode: .explicitAndImplicit) == nil)
    }

    @Test func testDetectorReplacesTheBuiltInPatternForTheRowScan() {
        let terminal = makeTerminal("target docs/a.md target", detector: Self.linking("target"))
        let ranges = terminal.implicitLinkRanges(inRows: 0..<3)
        #expect(ranges == [.init(row: 0, range: 0..<6), .init(row: 0, range: 17..<23)])
    }

    @Test func testEmptyRangesAreIgnored() {
        let terminal = makeTerminal("some text", detector: { text in [text.startIndex..<text.startIndex] })
        #expect(terminal.implicitLinkRanges(inRows: 0..<3).isEmpty)
        #expect(terminal.link(at: .buffer(Position(col: 0, row: 0)), mode: .explicitAndImplicit) == nil)
    }

    @Test func testWithoutADetectorTheBuiltInPatternIsUsed() {
        let terminal = makeTerminal("open docs/a.md now", detector: nil)
        #expect(terminal.link(at: .buffer(Position(col: 6, row: 0)), mode: .explicitAndImplicit) == "docs/a.md")
    }
}

//
//  StateSerializerTests.swift
//
//  Round-trip tests for Terminal.serializeState(): feed a terminal, serialize
//  it, feed the bytes into a fresh terminal with the same options and compare
//  what an application or a renderer can observe.
//

import Foundation
import Testing

@testable import SwiftTerm

private final class Sink: TerminalDelegate {
    var sent: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
}

private struct Pair {
    let sinkA = Sink()
    let sinkB = Sink()
    let a: Terminal
    let b: Terminal

    init(cols: Int = 20, rows: Int = 5, scrollback: Int = 100) {
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        a = Terminal(delegate: sinkA, options: options)
        b = Terminal(delegate: sinkB, options: options)
    }

    func feed(_ text: String) { a.feed(text: text) }

    /// Serializes `a` into `b`.
    func roundTrip() {
        b.feed(byteArray: a.serializeState())
    }
}

private func expectSameScreen(_ a: Terminal, _ b: Terminal, sourceLocation: SourceLocation = #_sourceLocation) {
    let linesA = a.buffer.lines, linesB = b.buffer.lines
    #expect(linesA.count == linesB.count, "line count", sourceLocation: sourceLocation)
    for index in 0..<min(linesA.count, linesB.count) {
        let lineA = linesA[index], lineB = linesB[index]
        #expect(lineA.translateToString(trimRight: true) == lineB.translateToString(trimRight: true),
                "text of line \(index)", sourceLocation: sourceLocation)
        #expect(lineA.isWrapped == lineB.isWrapped, "wrap of line \(index)", sourceLocation: sourceLocation)
        #expect(lineA.renderMode == lineB.renderMode, "render mode of line \(index)", sourceLocation: sourceLocation)
        for column in 0..<a.cols where lineA.hasContent(index: column) || lineB.hasContent(index: column) {
            let cellA = lineA[column], cellB = lineB[column]
            #expect(cellA.attribute == cellB.attribute, "attribute at \(index),\(column)", sourceLocation: sourceLocation)
            #expect(lineA.getWidth(index: column) == lineB.getWidth(index: column),
                    "width at \(index),\(column)", sourceLocation: sourceLocation)
            #expect(cellA.getPayload() as? String == cellB.getPayload() as? String,
                    "hyperlink at \(index),\(column)", sourceLocation: sourceLocation)
            #expect(cellA.semanticContent == cellB.semanticContent,
                    "semantic role at \(index),\(column)", sourceLocation: sourceLocation)
        }
    }
    #expect(a.buffer.x == b.buffer.x && a.buffer.y == b.buffer.y, "cursor", sourceLocation: sourceLocation)
    #expect(a.buffer.yBase == b.buffer.yBase, "scrollback length", sourceLocation: sourceLocation)
    #expect(a.currentAttribute == b.currentAttribute, "current attribute", sourceLocation: sourceLocation)
}

private func expectSameModes(_ a: Terminal, _ b: Terminal, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a.isCurrentBufferAlternate == b.isCurrentBufferAlternate, "alternate", sourceLocation: sourceLocation)
    #expect(a.applicationCursor == b.applicationCursor, "DECCKM", sourceLocation: sourceLocation)
    #expect(a.applicationKeypad == b.applicationKeypad, "keypad", sourceLocation: sourceLocation)
    #expect(a.bracketedPasteMode == b.bracketedPasteMode, "bracketed paste", sourceLocation: sourceLocation)
    #expect(a.mouseMode == b.mouseMode, "mouse mode", sourceLocation: sourceLocation)
    #expect(a.mouseProtocol == b.mouseProtocol, "mouse encoding", sourceLocation: sourceLocation)
    #expect(a.sendFocus == b.sendFocus, "focus", sourceLocation: sourceLocation)
    #expect(a.cursorHidden == b.cursorHidden, "DECTCEM", sourceLocation: sourceLocation)
    #expect(a.originMode == b.originMode, "DECOM", sourceLocation: sourceLocation)
    #expect(a.wraparound == b.wraparound, "DECAWM", sourceLocation: sourceLocation)
    #expect(a.insertMode == b.insertMode, "IRM", sourceLocation: sourceLocation)
    #expect(a.keyboardModeNormal.flags == b.keyboardModeNormal.flags
            && a.keyboardModeNormal.stack == b.keyboardModeNormal.stack, "kitty flags (normal)", sourceLocation: sourceLocation)
    #expect(a.keyboardModeAlt.flags == b.keyboardModeAlt.flags
            && a.keyboardModeAlt.stack == b.keyboardModeAlt.stack, "kitty flags (alternate)", sourceLocation: sourceLocation)
    #expect(a.buffer.scrollTop == b.buffer.scrollTop && a.buffer.scrollBottom == b.buffer.scrollBottom,
            "scroll region", sourceLocation: sourceLocation)
    #expect(a.options.cursorStyle == b.options.cursorStyle, "cursor style", sourceLocation: sourceLocation)
    #expect(a.terminalTitle == b.terminalTitle, "title", sourceLocation: sourceLocation)
    #expect(a.buffer.tabStops == b.buffer.tabStops, "tab stops", sourceLocation: sourceLocation)
    #expect(a.gLevel == b.gLevel && a.gCharsets.map { $0 == nil } == b.gCharsets.map { $0 == nil },
            "charsets", sourceLocation: sourceLocation)
}

@Suite("Terminal state serialization")
struct StateSerializerTests {
    @Test func plainLinesAndScrollback() {
        let pair = Pair()
        for index in 1...40 { pair.feed("line \(index)\r\n") }
        pair.feed("$ ")
        pair.roundTrip()
        expectSameScreen(pair.a, pair.b)
    }

    @Test func attributesAndColors() {
        let pair = Pair()
        pair.feed("\u{1b}[1;31mred\u{1b}[0m \u{1b}[38;5;200m256\u{1b}[0m \u{1b}[48;2;1;2;3mtrue\u{1b}[0m\r\n")
        pair.feed("\u{1b}[3;4:3;58;5;9mcurly\u{1b}[0m \u{1b}[7;9mrev\u{1b}[0m \u{1b}[2;5;8mhid\u{1b}[0m\r\n")
        pair.feed("\u{1b}[4mopen")
        pair.roundTrip()
        expectSameScreen(pair.a, pair.b)
    }

    @Test func wideCharactersAndWraps() {
        let pair = Pair(cols: 10)
        pair.feed("한글과 English 가 섞인 긴 줄은 이어진다\r\n")
        pair.feed("123456789가")   // the wide character does not fit in the last column
        pair.roundTrip()
        expectSameScreen(pair.a, pair.b)
    }

    @Test func gapsStayUnwritten() {
        let pair = Pair()
        pair.feed("a\u{1b}[5Cb\u{1b}[3;8Hc")
        pair.roundTrip()
        expectSameScreen(pair.a, pair.b)
        #expect(pair.b.buffer.lines[0].hasContent(index: 2) == false)
    }

    @Test func pendingWrap() {
        let pair = Pair(cols: 5)
        pair.feed("abcde")
        #expect(pair.a.buffer.x == 5)
        pair.roundTrip()
        expectSameScreen(pair.a, pair.b)
        pair.a.feed(text: "f")
        pair.b.feed(text: "f")
        expectSameScreen(pair.a, pair.b)
    }

    @Test func alternateScreenOverScrollback() {
        let pair = Pair()
        for index in 1...12 { pair.feed("shell \(index)\r\n") }
        pair.feed("\u{1b}[?1049h\u{1b}[2J\u{1b}[H\u{1b}[44mvim-like\u{1b}[0m\u{1b}[3;5Hstatus\u{1b}[2;2H")
        pair.roundTrip()
        expectSameModes(pair.a, pair.b)
        expectSameScreen(pair.a, pair.b)
        // Leaving the alternate screen restores the same shell screen and cursor.
        pair.a.feed(text: "\u{1b}[?1049l")
        pair.b.feed(text: "\u{1b}[?1049l")
        expectSameScreen(pair.a, pair.b)
    }

    @Test func modesAndKeyboardFlags() {
        let pair = Pair()
        pair.feed("\u{1b}[?1h\u{1b}=\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1004h\u{1b}[?25l\u{1b}[4h\u{1b}[5 q")
        pair.feed("\u{1b}[>1u\u{1b}[>3u\u{1b}]2;a title\u{1b}\\")
        pair.feed("\u{1b}[?1049h\u{1b}[>8u")
        pair.roundTrip()
        expectSameModes(pair.a, pair.b)
    }

    @Test func scrollRegionAndOriginMode() {
        let pair = Pair(rows: 8)
        pair.feed("top\r\n\u{1b}[2;6r\u{1b}[?6h\u{1b}[3;4Hin region")
        pair.roundTrip()
        expectSameModes(pair.a, pair.b)
        expectSameScreen(pair.a, pair.b)
    }

    @Test func savedCursor() {
        let pair = Pair()
        pair.feed("\u{1b}[3;7H\u{1b}[1;32m\u{1b}7\u{1b}[0m\u{1b}[1;1Hx")
        pair.roundTrip()
        pair.a.feed(text: "\u{1b}8y")
        pair.b.feed(text: "\u{1b}8y")
        expectSameScreen(pair.a, pair.b)
    }

    @Test func hyperlinksAndTabStops() {
        let pair = Pair()
        pair.feed("\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\ plain \u{1b}]8;id=1;file:///tmp\u{1b}\\open")
        pair.feed("\u{1b}[3g\u{1b}[1;4H\u{1b}H\u{1b}[1;11H\u{1b}H\u{1b}[2;1H")
        pair.roundTrip()
        expectSameScreen(pair.a, pair.b)
        expectSameModes(pair.a, pair.b)
        // The open hyperlink continues on the next printed cell.
        pair.a.feed(text: "z")
        pair.b.feed(text: "z")
        expectSameScreen(pair.a, pair.b)
    }

    @Test func charsetsAndLineRenderModes() {
        let pair = Pair()
        pair.feed("\u{1b}(0lqk\u{1b}(B\r\n\u{1b}#6wide\r\n\u{1b})0\u{0e}")
        pair.roundTrip()
        expectSameScreen(pair.a, pair.b)
        expectSameModes(pair.a, pair.b)
    }

    @Test func semanticRoles() {
        let pair = Pair()
        pair.feed("\u{1b}]133;A\u{1b}\\$ \u{1b}]133;B\u{1b}\\ls\r\n\u{1b}]133;C\u{1b}\\out\r\n")
        pair.roundTrip()
        expectSameScreen(pair.a, pair.b)
    }

    @Test func noRepliesFromTheStreamExceptReports() {
        let pair = Pair()
        pair.feed("\u{1b}[?1049h\u{1b}[?2004hhello")
        pair.roundTrip()
        #expect(pair.sinkB.sent.isEmpty)
    }
}

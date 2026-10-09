//
//  LinkRevealMotionTests.swift
//
//  Revealing links while Command is held: when they appear, how the reveal
//  eases, how strongly each link is drawn, and where its marks go.
//

#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
struct LinkRevealMotionTests {
    private typealias RowRange = Terminal.LinkMatch.RowRange

    private static let duration: TimeInterval = 0.14

    private func color() -> FrameColor {
        FrameColor(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), view: TerminalView(frame: .zero))
    }

    private func frame(opacity: Double = 1, presence: Double = 1, pointerRow: Double = 0, reach: Double = 6,
                       hovers: [LinkRevealFrame.Hover] = []) -> LinkRevealFrame {
        LinkRevealFrame(color: color(), opacity: opacity, presence: presence, pointerRow: pointerRow,
                        reach: reach, hovers: hovers)
    }

    // MARK: When links appear

    @Test func commandAloneRevealsAfterTheDelay() {
        var intent = LinkRevealIntent(delay: 0.18, pointerTravel: 6)
        intent.commandPressed(at: 10, pointer: nil)
        #expect(intent.isArmed && !intent.isShown)
        let early = intent.advance(to: 10.1)
        #expect(!early)
        let onTime = intent.advance(to: 10.2)
        #expect(onTime)
        #expect(intent.isShown)
    }

    @Test func anotherKeyMakesItAShortcut() {
        var intent = LinkRevealIntent(delay: 0.18, pointerTravel: 6)
        intent.commandPressed(at: 0, pointer: nil)
        intent.keyPressed()
        let afterShortcut = intent.advance(to: 1)
        #expect(!afterShortcut)
        #expect(!intent.isShown && intent.isArmed)
        intent.commandReleased()
        #expect(!intent.isArmed)
    }

    @Test func aKeyHidesLinksAlreadyShown() {
        var intent = LinkRevealIntent(delay: 0.18, pointerTravel: 6)
        intent.commandPressed(at: 0, pointer: nil)
        let shown = intent.advance(to: 0.2)
        #expect(shown)
        intent.keyPressed()
        #expect(!intent.isShown)
    }

    @Test func pointerTravelRevealsAtOnce() {
        var intent = LinkRevealIntent(delay: 0.18, pointerTravel: 6)
        intent.commandPressed(at: 0, pointer: CGPoint(x: 100, y: 100))
        let afterTremor = intent.pointerMoved(to: CGPoint(x: 104, y: 103))   // 5 points: a tremor
        #expect(!afterTremor)
        let afterTravel = intent.pointerMoved(to: CGPoint(x: 107, y: 100))
        #expect(afterTravel)
        #expect(intent.isShown)
    }

    @Test func travelIsMeasuredFromTheFirstPointWhenThePointerWasElsewhere() {
        var intent = LinkRevealIntent(delay: 0.18, pointerTravel: 6)
        intent.commandPressed(at: 0, pointer: nil)
        let atFirstPoint = intent.pointerMoved(to: CGPoint(x: 0, y: 0))
        #expect(!atFirstPoint)
        let afterTravel = intent.pointerMoved(to: CGPoint(x: 0, y: 10))
        #expect(afterTravel)
    }

    @Test func zeroDelayRevealsOnPress() {
        var intent = LinkRevealIntent(delay: 0, pointerTravel: 6)
        intent.commandPressed(at: 0, pointer: nil)
        #expect(intent.isShown)
    }

    // MARK: Easing

    @Test func transitionMovesLinearlyAndRetargetsFromWhereItIs() {
        var value = LinkRevealTransition(0)
        value.move(to: 1, at: 0, duration: 0.1)
        #expect(abs(value.value(at: 0.05, duration: 0.1) - 0.5) < 1e-9)
        value.move(to: 0, at: 0.05, duration: 0.1)
        #expect(abs(value.value(at: 0.05, duration: 0.1) - 0.5) < 1e-9)
        #expect(abs(value.value(at: 0.1, duration: 0.1) - 0.25) < 1e-9)
        #expect(value.isSettled(at: 0.16, duration: 0.1))
        #expect(value.value(at: 0.16, duration: 0.1) == 0)
    }

    @Test func revealFadesInAndOut() {
        var motion = LinkRevealMotion(duration: Self.duration)
        #expect(motion.frame(at: 0, color: color(), reach: 6) == nil)
        motion.setShown(true, at: 0)
        #expect(motion.isAnimating(at: 0.07))
        #expect(abs((motion.frame(at: 0.07, color: color(), reach: 6)?.opacity ?? 0) - 0.5) < 1e-9)
        #expect(!motion.isAnimating(at: 0.14))
        motion.setShown(false, at: 1)
        #expect(motion.frame(at: 1.15, color: color(), reach: 6) == nil)
    }

    @Test func reduceMotionIsImmediate() {
        var motion = LinkRevealMotion(duration: 0)
        motion.setShown(true, at: 0)
        #expect(motion.frame(at: 0, color: color(), reach: 6)?.opacity == 1)
        #expect(!motion.isAnimating(at: 0))
    }

    @Test func comingBackStartsWhereThePointerIs() {
        var motion = LinkRevealMotion(duration: Self.duration)
        motion.setShown(true, at: 0)
        motion.setPointerRow(3, at: 0)
        motion.setPointerRow(nil, at: 1)
        motion.setPointerRow(40, at: 2)
        #expect(motion.frame(at: 2, color: color(), reach: 6)?.pointerRow == 40)
        motion.setPointerRow(42, at: 3)
        #expect(motion.frame(at: 3.07, color: color(), reach: 6)?.pointerRow == 41)
    }

    @Test func hoverFadesAndIsDroppedOnceGone() {
        let a = [RowRange(row: 0, range: 0..<4)]
        let b = [RowRange(row: 1, range: 0..<4)]
        var motion = LinkRevealMotion(duration: Self.duration)
        motion.setShown(true, at: 0)
        motion.setHoveredLink(a, at: 0)
        motion.setHoveredLink(b, at: 1)
        let hovers = motion.frame(at: 1.07, color: color(), reach: 6)?.hovers ?? []
        #expect(hovers.map(\.link) == [a, b])
        motion.setHoveredLink(nil, at: 2)
        #expect(motion.hovers.map(\.link) == [b])     // a has faded out; b is fading
        motion.setShown(true, at: 3)
        #expect(motion.hovers.isEmpty)
    }

    // MARK: Emphasis

    @Test func linksAreFaintWithoutThePointer() {
        let emphasis = frame(presence: 0).emphasis(of: [RowRange(row: 0, range: 0..<4)])
        #expect(emphasis.underline == LinkRevealFrame.restingUnderline)
        #expect(emphasis.fill == 0)
    }

    @Test func emphasisFallsOffWithRowsFromThePointer() {
        let onRow = frame(pointerRow: 5).emphasis(of: [RowRange(row: 5, range: 0..<4)])
        #expect(abs(onRow.underline - 1) < 1e-9)
        #expect(onRow.fill == LinkRevealFrame.fill)

        let halfway = frame(pointerRow: 5).emphasis(of: [RowRange(row: 8, range: 0..<4)])
        #expect(abs(halfway.underline - 0.6) < 1e-9)
        #expect(abs(halfway.fill - 0.05) < 1e-9)

        let far = frame(pointerRow: 5).emphasis(of: [RowRange(row: 20, range: 0..<4)])
        #expect(far.underline == LinkRevealFrame.restingUnderline)
        #expect(far.fill == 0)
    }

    @Test func aWrappedLinkTakesItsNearestRow() {
        let link = [RowRange(row: 4, range: 6..<10), RowRange(row: 5, range: 0..<3)]
        #expect(abs(frame(pointerRow: 5).emphasis(of: link).underline - 1) < 1e-9)
    }

    @Test func theLinkUnderThePointerIsStrongest() {
        let link = [RowRange(row: 9, range: 0..<4)]
        let emphasis = frame(pointerRow: 0, hovers: [.init(link: link, amount: 1)]).emphasis(of: link)
        #expect(abs(emphasis.underline - 1) < 1e-9)
        #expect(emphasis.fill == LinkRevealFrame.hoverFill)
    }

    @Test func fadingScalesEverything() {
        let emphasis = frame(opacity: 0.5, presence: 0).emphasis(of: [RowRange(row: 0, range: 0..<4)])
        #expect(emphasis.underline == LinkRevealFrame.restingUnderline / 2)
    }

    // MARK: Marks

    private let metrics = LinkRevealPaint.Metrics(cellWidth: 8, cellHeight: 16, baselineOffset: 4,
                                                  underlinePosition: -1)

    @Test func marksSitOnTheLinkCells() throws {
        let reveal = SnapshotLinkReveal(links: [[RowRange(row: 2, range: 3..<7)]], frame: frame(pointerRow: 2))
        let paint = LinkRevealPaint(reveal: reveal, metrics: metrics, selection: { _ in nil }, isDecorated: { _ in true })
        let outset = LinkRevealPaint.fillOutset
        let inset = LinkRevealPaint.fillInset
        #expect(paint.fills[2] == [.init(minX: 24 - outset, width: 32 + 2 * outset, minY: inset,
                                         height: 16 - 2 * inset, alpha: CGFloat(LinkRevealFrame.fill))])
        let thickness = LinkRevealPaint.underlineThickness
        let underline = try #require(paint.underlines[2]?.first)
        #expect(paint.underlines[2]?.count == 1)
        #expect(underline.rect(rowMinY: 0) == CGRect(x: 24, y: 3 - thickness / 2, width: 32, height: thickness))
        #expect(abs(underline.alpha - 1) < 1e-9)
    }

    @Test func aFarLinkGetsNoFill() {
        let reveal = SnapshotLinkReveal(links: [[RowRange(row: 30, range: 0..<4)]], frame: frame(pointerRow: 0))
        let paint = LinkRevealPaint(reveal: reveal, metrics: metrics, selection: { _ in nil }, isDecorated: { _ in true })
        #expect(paint.fills.isEmpty)
        #expect(paint.underlines[30]?.count == 1)
    }

    @Test func theSelectionCutsTheMarks() {
        let reveal = SnapshotLinkReveal(links: [[RowRange(row: 0, range: 0..<10)]], frame: frame())
        let paint = LinkRevealPaint(reveal: reveal, metrics: metrics, selection: { _ in 3..<5 }, isDecorated: { _ in true })
        #expect(paint.underlines[0]?.map(\.minX) == [0, 40])
        #expect(paint.underlines[0]?.map(\.width) == [24, 40])
        #expect(LinkRevealPaint.pieces(of: 2..<6, excluding: 0..<10).isEmpty)
    }

    @Test func doubleSizeRowsAreNotDecorated() {
        let reveal = SnapshotLinkReveal(links: [[RowRange(row: 0, range: 0..<4)]], frame: frame())
        let paint = LinkRevealPaint(reveal: reveal, metrics: metrics, selection: { _ in nil }, isDecorated: { _ in false })
        #expect(paint.isEmpty)
    }
}
#endif

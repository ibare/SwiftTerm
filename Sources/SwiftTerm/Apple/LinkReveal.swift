//
//  LinkReveal.swift
//
//  Revealing every visible link while Command is held (macOS): when the links
//  appear, how they ease in and out, and what the renderers paint for them.
//
//  The view owns a LinkRevealIntent (when) and a LinkRevealMotion (how far
//  along), both on the main thread. Every frame samples them into a
//  LinkRevealFrame that travels in FrameViewState with the rest of the view
//  state. The snapshot adds the links on screen, and LinkRevealPaint turns the
//  two into fills and underlines that the Core Graphics and Metal renderers
//  draw: fills between the cell backgrounds and the glyphs, underlines over
//  the glyphs. The text itself is left alone.
//
//  Emphasis follows the pointer. Every link gets a faint underline; the closer
//  a link is to the pointer's row, the stronger its underline and the more of
//  a fill it gets behind it, and the link under the pointer gets the most.
//  Links far from where the user is looking stay quiet.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS) || os(tvOS)
import Foundation
import CoreGraphics

/// When holding Command reveals links.
///
/// Command is mostly half of a shortcut, so pressing it shows nothing at first.
/// Links appear once Command has been held alone for `delay`, or at once when
/// the pointer travels more than `pointerTravel` while it is held: moving the
/// pointer is what a Command-click is about to need. Any other key pressed with
/// Command makes the press a shortcut, and links stay hidden until Command is
/// released.
struct LinkRevealIntent: Equatable {
    enum Phase: Equatable {
        /// Command is up.
        case idle
        /// Command is held alone. Links appear at `deadline` unless something
        /// else happens first. `origin` is where the pointer was over the view,
        /// once known.
        case pending(deadline: TimeInterval, origin: CGPoint?)
        case shown
        /// Another key joined Command: a shortcut. Nothing shows until Command
        /// is released.
        case suppressed
    }

    let delay: TimeInterval
    let pointerTravel: CGFloat
    private(set) var phase: Phase = .idle

    init(delay: TimeInterval, pointerTravel: CGFloat) {
        self.delay = delay
        self.pointerTravel = pointerTravel
    }

    var isShown: Bool { phase == .shown }

    /// Command is held, whether or not links show.
    var isArmed: Bool { phase != .idle }

    /// When the pending delay runs out, if it is running.
    var deadline: TimeInterval? {
        if case .pending(let deadline, _) = phase {
            return deadline
        }
        return nil
    }

    /// Command went down. `pointer` is where the pointer is in view
    /// coordinates, when it is over the view.
    mutating func commandPressed(at time: TimeInterval, pointer: CGPoint?) {
        guard phase == .idle else { return }
        phase = delay > 0 ? .pending(deadline: time + delay, origin: pointer) : .shown
    }

    /// Lets the delay run out. Returns true when this shows the links.
    mutating func advance(to time: TimeInterval) -> Bool {
        guard case .pending(let deadline, _) = phase, time >= deadline else { return false }
        phase = .shown
        return true
    }

    /// The pointer moved to `point`, in view coordinates, while over the view.
    /// Returns true when this shows the links.
    mutating func pointerMoved(to point: CGPoint) -> Bool {
        guard case .pending(let deadline, let origin) = phase else { return false }
        guard let origin else {
            phase = .pending(deadline: deadline, origin: point)
            return false
        }
        guard hypot(point.x - origin.x, point.y - origin.y) > pointerTravel else { return false }
        phase = .shown
        return true
    }

    /// Another key went down while Command is held.
    mutating func keyPressed() {
        guard phase != .idle else { return }
        phase = .suppressed
    }

    /// Command went up, or the view stopped receiving keys.
    mutating func commandReleased() {
        phase = .idle
    }
}

/// A value that moves linearly to its target over a fixed duration and can be
/// retargeted mid-way, starting again from wherever it is.
struct LinkRevealTransition: Equatable {
    private(set) var from: Double
    private(set) var to: Double
    private(set) var start: TimeInterval = 0

    init(_ value: Double) {
        from = value
        to = value
    }

    func value(at time: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, from != to else { return to }
        let progress = min(1, max(0, (time - start) / duration))
        return from + (to - from) * progress
    }

    func isSettled(at time: TimeInterval, duration: TimeInterval) -> Bool {
        from == to || duration <= 0 || time - start >= duration
    }

    mutating func move(to target: Double, at time: TimeInterval, duration: TimeInterval) {
        guard target != to else { return }
        from = value(at: time, duration: duration)
        to = target
        start = time
    }

    mutating func jump(to target: Double) {
        from = target
        to = target
    }
}

/// How far along the reveal is: how visible the links are, where the pointer
/// is, and which link it is on. Every change eases over `duration`; zero (for
/// Reduce Motion) makes them immediate.
struct LinkRevealMotion {
    struct Hover: Equatable {
        let link: [Terminal.LinkMatch.RowRange]
        var amount: LinkRevealTransition
    }

    var duration: TimeInterval
    private var opacity = LinkRevealTransition(0)
    private var presence = LinkRevealTransition(0)
    private var pointerRow = LinkRevealTransition(0)
    private(set) var hovers: [Hover] = []
    private var hoveredLink: [Terminal.LinkMatch.RowRange]?

    init(duration: TimeInterval) {
        self.duration = duration
    }

    /// Shows or hides the links.
    mutating func setShown(_ shown: Bool, at time: TimeInterval) {
        opacity.move(to: shown ? 1 : 0, at: time, duration: duration)
        prune(at: time)
    }

    /// The pointer is over buffer row `row`, or not over the view when nil.
    mutating func setPointerRow(_ row: Int?, at time: TimeInterval) {
        guard let row else {
            presence.move(to: 0, at: time, duration: duration)
            return
        }
        // Coming back from outside, emphasis starts where the pointer is
        // rather than sweeping over from where it left.
        if presence.value(at: time, duration: duration) == 0 {
            pointerRow.jump(to: Double(row))
        } else {
            pointerRow.move(to: Double(row), at: time, duration: duration)
        }
        presence.move(to: 1, at: time, duration: duration)
    }

    /// The pointer is over `link`, or over no link when nil.
    mutating func setHoveredLink(_ link: [Terminal.LinkMatch.RowRange]?, at time: TimeInterval) {
        guard link != hoveredLink else { return }
        if let old = hoveredLink, let index = hovers.firstIndex(where: { $0.link == old }) {
            hovers[index].amount.move(to: 0, at: time, duration: duration)
        }
        if let link {
            if let index = hovers.firstIndex(where: { $0.link == link }) {
                hovers[index].amount.move(to: 1, at: time, duration: duration)
            } else {
                var amount = LinkRevealTransition(0)
                amount.move(to: 1, at: time, duration: duration)
                hovers.append(Hover(link: link, amount: amount))
            }
        }
        hoveredLink = link
        prune(at: time)
    }

    /// Whether a later sample will differ from this one.
    func isAnimating(at time: TimeInterval) -> Bool {
        !opacity.isSettled(at: time, duration: duration) ||
            !presence.isSettled(at: time, duration: duration) ||
            !pointerRow.isSettled(at: time, duration: duration) ||
            hovers.contains { !$0.amount.isSettled(at: time, duration: duration) }
    }

    /// What a frame drawn at `time` shows, or nil when the links are hidden.
    func frame(at time: TimeInterval, color: FrameColor, reach: Int) -> LinkRevealFrame? {
        let opacity = opacity.value(at: time, duration: duration)
        guard opacity > 0 else { return nil }
        let hovers = hovers.compactMap { hover -> LinkRevealFrame.Hover? in
            let amount = hover.amount.value(at: time, duration: duration)
            return amount > 0 ? LinkRevealFrame.Hover(link: hover.link, amount: amount) : nil
        }
        return LinkRevealFrame(color: color,
                               opacity: opacity,
                               presence: presence.value(at: time, duration: duration),
                               pointerRow: pointerRow.value(at: time, duration: duration),
                               reach: Double(reach),
                               hovers: hovers)
    }

    /// Drops hovers that have faded out.
    private mutating func prune(at time: TimeInterval) {
        hovers.removeAll { hover in
            hover.link != hoveredLink &&
                hover.amount.isSettled(at: time, duration: duration) &&
                hover.amount.value(at: time, duration: duration) == 0
        }
    }
}

/// The reveal as one frame draws it, sampled on the main thread.
struct LinkRevealFrame: Sendable, Equatable {
    struct Hover: Sendable, Equatable {
        let link: [Terminal.LinkMatch.RowRange]
        let amount: Double
    }

    /// How strongly one link is drawn, as opacities of the reveal color.
    struct Emphasis: Equatable {
        let underline: Double
        let fill: Double
    }

    /// Underline opacity of a link far from the pointer, or of every link
    /// while the pointer is not over the view.
    static let restingUnderline = 0.2
    /// Fill opacity of a link on the pointer's row.
    static let fill = 0.2
    /// Fill opacity of the link under the pointer.
    static let hoverFill = 0.26

    let color: FrameColor
    /// How visible the links are, fading in and out.
    let opacity: Double
    /// How much the pointer is over the view, fading as it enters and leaves.
    let presence: Double
    /// The buffer row the pointer is over, easing between rows.
    let pointerRow: Double
    /// Rows from the pointer over which emphasis fades out.
    let reach: Double
    let hovers: [Hover]

    /// How strongly `link`, given by its cell range on each row, is drawn.
    ///
    /// Nearness `p` runs from 1 on the pointer's row to 0 at `reach` rows away.
    /// The underline goes from ``restingUnderline`` to fully opaque with `p`,
    /// and the fill grows with `p` squared, so only links right by the pointer
    /// get much of one. The link under the pointer is drawn at full underline
    /// and ``hoverFill``.
    func emphasis(of link: [Terminal.LinkMatch.RowRange]) -> Emphasis {
        let distance = link.map { abs(Double($0.row) - pointerRow) }.min() ?? .infinity
        let nearness = reach > 0 ? max(0, 1 - distance / reach) : 0
        let p = presence * nearness
        let hover = hovers.first { $0.link == link }?.amount ?? 0
        let underline = Self.restingUnderline + (1 - Self.restingUnderline) * p
        let fill = Self.fill * p * p
        return Emphasis(underline: opacity * (underline + (1 - underline) * hover),
                        fill: opacity * (fill + (Self.hoverFill - fill) * hover))
    }
}

/// The links a snapshot shows while they are revealed.
struct SnapshotLinkReveal: Equatable {
    /// Every visible link, explicit and implicit, as its cell range on each row.
    let links: [[Terminal.LinkMatch.RowRange]]
    let frame: LinkRevealFrame
}

/// What the renderers draw for revealed links in one frame.
///
/// Marks are kept per buffer row, in points relative to the row: `minX` from
/// the view's leading edge and `minY` up from the row's bottom edge, the way
/// the Core Graphics draw lays rows out. Only single-width rows are decorated.
struct LinkRevealPaint {
    struct Mark: Equatable {
        let minX: CGFloat
        let width: CGFloat
        let minY: CGFloat
        let height: CGFloat
        /// Opacity of the reveal color.
        let alpha: CGFloat

        /// The mark's rectangle for a row whose bottom edge is at `rowMinY`.
        func rect(rowMinY: CGFloat) -> CGRect {
            CGRect(x: minX, y: rowMinY + minY, width: width, height: height)
        }
    }

    /// Cell and font metrics the marks are laid out with.
    struct Metrics: Equatable {
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        /// From the row's bottom edge up to the baseline.
        let baselineOffset: CGFloat
        /// From the baseline to the underline's center, negative below.
        let underlinePosition: CGFloat
    }

    static let underlineThickness: CGFloat = 1.5
    static let fillCornerRadius: CGFloat = 4
    /// How far a fill reaches past the link's first and last cells.
    static let fillOutset: CGFloat = 2
    /// How far a fill stays from the row's top and bottom edges, so fills on
    /// adjacent rows do not run together.
    static let fillInset: CGFloat = 1

    let color: FrameColor
    private(set) var fills: [Int: [Mark]] = [:]
    private(set) var underlines: [Int: [Mark]] = [:]

    /// - Parameters:
    ///   - selection: the selected columns of a buffer row. A selection wins
    ///     over a revealed link: the user is acting on it.
    ///   - isDecorated: whether a buffer row is drawn at single width.
    init(reveal: SnapshotLinkReveal,
         metrics: Metrics,
         selection: (Int) -> Range<Int>?,
         isDecorated: (Int) -> Bool) {
        color = reveal.frame.color
        let underlineY = metrics.baselineOffset + metrics.underlinePosition - Self.underlineThickness / 2
        let fillHeight = max(0, metrics.cellHeight - 2 * Self.fillInset)
        for link in reveal.links {
            let emphasis = reveal.frame.emphasis(of: link)
            for rowRange in link where isDecorated(rowRange.row) {
                for piece in Self.pieces(of: rowRange.range, excluding: selection(rowRange.row)) {
                    let minX = CGFloat(piece.lowerBound) * metrics.cellWidth
                    let width = CGFloat(piece.count) * metrics.cellWidth
                    if emphasis.fill > 0 {
                        fills[rowRange.row, default: []].append(Mark(
                            minX: minX - Self.fillOutset,
                            width: width + 2 * Self.fillOutset,
                            minY: Self.fillInset,
                            height: fillHeight,
                            alpha: CGFloat(emphasis.fill)))
                    }
                    if emphasis.underline > 0 {
                        underlines[rowRange.row, default: []].append(Mark(
                            minX: minX,
                            width: width,
                            minY: underlineY,
                            height: Self.underlineThickness,
                            alpha: CGFloat(emphasis.underline)))
                    }
                }
            }
        }
    }

    var isEmpty: Bool { fills.isEmpty && underlines.isEmpty }

    /// `range` without the columns in `excluded`.
    static func pieces(of range: Range<Int>, excluding excluded: Range<Int>?) -> [Range<Int>] {
        guard let excluded, excluded.overlaps(range) else { return [range] }
        var result: [Range<Int>] = []
        if range.lowerBound < excluded.lowerBound {
            result.append(range.lowerBound..<excluded.lowerBound)
        }
        if excluded.upperBound < range.upperBound {
            result.append(excluded.upperBound..<range.upperBound)
        }
        return result
    }
}

#endif
#endif

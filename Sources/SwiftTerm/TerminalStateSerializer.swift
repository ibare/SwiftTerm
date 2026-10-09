//
//  TerminalStateSerializer.swift
//
//  Encodes a terminal's state as a VT byte stream. Feeding the stream into a
//  freshly created terminal with the same options and size reproduces the
//  screen, the scrollback, the cursor and the modes that applications set.
//
//  This lets a process that keeps a terminal alive (a session keeper, for
//  example) hand the current screen to a view that attaches later, using the
//  same parser the view already has instead of a separate snapshot format.
//
//  What is reproduced:
//    - Both buffers: every line of the normal buffer (scrollback included) and
//      the alternate buffer when it is active, with characters, graphemes,
//      wide characters, SGR attributes (colors, styles, underline style and
//      color), OSC 8 hyperlinks, OSC 133 semantic roles, soft wraps and line
//      render modes (DECDWL/DECDHL).
//    - Per buffer: cursor position, the DECSC saved cursor (position,
//      attribute, charset, origin, wraparound, margin and reverse-wraparound
//      modes), scroll region, left/right margins, kitty keyboard flags and
//      their stack.
//    - Terminal modes that DECRQM reports, mouse tracking and its encoding,
//      bracketed paste, focus, alternate scroll, color-scheme, visibility and
//      in-band size reports, kitty paste events, insert and line feed modes,
//      the keypad mode, cursor style, tab stops, G0–G3 charsets and the shift
//      level, the current attribute and hyperlink, the pending-wrap state,
//      titles and the OSC 6/7 locations.
//
//  What is not:
//    - Images (sixel, kitty graphics) and their placements.
//    - Palette changes (OSC 4/10/11/12) — the host owns the theme.
//    - Modes saved with XTSAVE, an in-progress synchronized update (2026),
//      a pending DCS/OSC, the viewport scroll position and selections.
//    - OSC 133 bookkeeping beyond the cell roles: prompt groups, click
//      options and row marks are rebuilt by the receiver from the role marks
//      (`133;P`, `133;B`, `133;C`), which never move the cursor. A role cannot
//      return to `.none` without a reset, and continuation prompts are marked
//      as secondary prompts.
//
//  Some modes make the receiving terminal send a report when they are turned
//  on (visibility, in-band size). A host that feeds this stream must drop
//  what its terminal sends while it does so.
//

#if !SWIFTTERM_EMBEDDED
import Foundation
#endif

extension Terminal {
    /// Returns a byte stream that reproduces this terminal's state when fed
    /// into a new terminal created with the same options, columns and rows.
    ///
    /// Call this on the same thread or queue that feeds the terminal.
    public func serializeState() -> [UInt8] {
        var writer = StateWriter(terminal: self)
        writer.write()
        return writer.bytes
    }
}

/// Builds the state stream. It tracks what the receiving terminal will have
/// at each point so that it only emits changes.
private struct StateWriter {
    let terminal: Terminal
    var bytes: [UInt8] = []

    /// SGR attribute, semantic role and hyperlink the receiver uses for the
    /// next printed cell.
    private var attribute = CharData.defaultAttr
    private var semantic: SemanticContent = .none
    private var hyperlink: String? = nil

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    mutating func write() {
        let normal = terminal.normalBuffer
        let alternate = terminal.isCurrentBufferAlternate

        // The normal buffer, then its per-buffer state. When the alternate
        // buffer is active this state waits underneath it, exactly as the
        // application left it.
        writeLines(of: normal, from: 0)
        writeBufferState(normal, final: !alternate)

        if alternate {
            // 1047 switches without saving the cursor; the saved cursor was
            // reproduced by writeBufferState above.
            csi("?1047h")
            csi("H")   // the cursor keeps the normal buffer's row; lines are written from the top
            resetPrinting()
            writeLines(of: terminal.altBuffer, from: terminal.altBuffer.yBase)
            writeBufferState(terminal.altBuffer, final: true)
        }
        writeTerminalModes()
        writeCursor(of: terminal.buffer)
    }

    // MARK: Lines

    /// Writes the lines of a buffer from the top, so that the lines above the
    /// screen scroll into the receiver's scrollback.
    private mutating func writeLines(of buffer: Buffer, from start: Int) {
        let lines = buffer.lines
        let count = lines.count
        let cols = terminal.cols
        guard start < count else { return }
        for index in start..<count {
            let line = lines[index]
            if index > start {
                let continues = line.isWrapped
                if !continues {
                    bytes.append(13)
                    bytes.append(10)
                }
            }
            writeRenderMode(line.renderMode)
            writeCells(of: line, cols: cols, wrapsIntoNext: index + 1 < count && lines[index + 1].isWrapped)
        }
    }

    private mutating func writeRenderMode(_ mode: BufferLine.RenderLineMode) {
        switch mode {
        case .single: break
        case .doubleWidth: esc("#6")
        case .doubledTop: esc("#3")
        case .doubledDown: esc("#4")
        }
    }

    /// Writes the cells of one line. Unwritten cells are skipped with cursor
    /// movement so that they stay unwritten. When the next line continues this
    /// one, the cursor must end in the pending-wrap state for the receiver to
    /// mark that line as wrapped too.
    private mutating func writeCells(of line: BufferLine, cols: Int, wrapsIntoNext: Bool) {
        let width = min(cols, line.count)
        var lastContent = -1
        for column in 0..<width where cellHasContent(line, column) {
            lastContent = column
        }
        var column = 0
        var cursor = 0
        while column <= lastContent {
            let cell = line[column]
            let cellWidth = max(1, Int(line.getWidth(index: column)))
            if !cellHasContent(line, column) {
                column += 1
                continue
            }
            if column > cursor {
                csi("\(column - cursor)C")
                cursor = column
            }
            setCellState(cell)
            let text = cell.code == 0 ? " " : cell.getText()
            bytes.append(contentsOf: Array(text.utf8))
            column += cellWidth
            cursor = column
        }
        if wrapsIntoNext && cursor < cols {
            // A wide character that did not fit leaves the last column empty
            // and wraps. Move to the end so that the next character wraps the
            // same way.
            if cols - cursor > 1 {
                csi("\(cols - cursor - 1)C")
            }
        }
    }

    private func cellHasContent(_ line: BufferLine, _ column: Int) -> Bool {
        let cell = line[column]
        if line.getWidth(index: column) == 0 && cell.code == 0 {
            return false   // the second half of a wide character
        }
        return cell.code != 0 || cell.attribute != CharData.defaultAttr || cell.semanticContent != .none
            || cell.hasPayload
    }

    private mutating func setCellState(_ cell: CharData) {
        setAttribute(cell.attribute)
        if cell.semanticContent != semantic {
            setSemantic(cell.semanticContent)
        }
        let link = cell.getPayload() as? String
        if link != hyperlink {
            osc("8;" + (link ?? ";"))
            hyperlink = link
        }
    }

    /// Role marks that never move the cursor (`A` would start a fresh line).
    private mutating func setSemantic(_ content: SemanticContent) {
        switch content {
        case .prompt(.initial): osc("133;P;k=i")
        case .prompt(.right): osc("133;P;k=r")
        case .prompt(.secondary), .prompt(.continuation): osc("133;P;k=s")
        case .input: osc("133;B")
        case .output: osc("133;C")
        case .none: return   // no mark returns a cell to .none (see the file header)
        }
        semantic = content
    }

    private mutating func resetPrinting() {
        attribute = CharData.defaultAttr
        semantic = .none
        hyperlink = nil
    }

    // MARK: Attributes

    private mutating func setAttribute(_ next: Attribute) {
        guard next != attribute else { return }
        csi(Self.sgr(next) + "m")
        attribute = next
    }

    /// A complete SGR for an attribute, starting from a reset.
    static func sgr(_ attribute: Attribute) -> String {
        var parts = ["0"]
        let style = attribute.style
        if style.contains(.bold) { parts.append("1") }
        if style.contains(.dim) { parts.append("2") }
        if style.contains(.italic) { parts.append("3") }
        if style.contains(.underline) {
            switch attribute.underlineStyle {
            case .none, .single: parts.append("4")
            case .double: parts.append("4:2")
            case .curly: parts.append("4:3")
            case .dotted: parts.append("4:4")
            case .dashed: parts.append("4:5")
            }
        }
        if style.contains(.blink) { parts.append("5") }
        if style.contains(.inverse) { parts.append("7") }
        if style.contains(.invisible) { parts.append("8") }
        if style.contains(.crossedOut) { parts.append("9") }
        if let fg = color(attribute.fg, base: 38) { parts.append(fg) }
        if let bg = color(attribute.bg, base: 48) { parts.append(bg) }
        if let underline = attribute.underlineColor, let encoded = color(underline, base: 58) { parts.append(encoded) }
        return parts.joined(separator: ";")
    }

    private static func color(_ color: Attribute.Color, base: Int) -> String? {
        switch color {
        case .ansi256(let code): "\(base);5;\(code)"
        case .trueColor(let red, let green, let blue): "\(base);2;\(red);\(green);\(blue)"
        case .defaultColor, .defaultInvertedColor: nil
        }
    }

    // MARK: Buffer state

    /// Saved cursor, scroll region, margins and kitty keyboard flags of a
    /// buffer. Must run while the buffer is active.
    private mutating func writeBufferState(_ buffer: Buffer, final: Bool) {
        writeSavedCursor(of: buffer)
        writeKeyboardFlags(buffer === terminal.altBuffer ? terminal.keyboardModeAlt : terminal.keyboardModeNormal)
        writeMargins(of: buffer)
        if !final {
            writeCursor(of: buffer, withMode: false)
        }
    }

    private mutating func writeSavedCursor(of buffer: Buffer) {
        let isDefault = buffer.savedX == 0 && buffer.savedY == 0 && buffer.savedAttr == CharData.defaultAttr
            && buffer.savedCharset == nil && !buffer.savedOriginMode && !buffer.savedMarginMode
            && buffer.savedWraparound && !buffer.savedReverseWraparound
        guard !isDefault else { return }
        // Put the receiver in the saved state, save it, then return to the
        // defaults that line writing and later steps assume.
        if buffer.savedReverseWraparound { csi("?45h") }
        if buffer.savedMarginMode { csi("?69h") }
        if !buffer.savedWraparound { csi("?7l") }
        csi("\(buffer.savedY + 1);\(buffer.savedX + 1)H")
        if buffer.savedOriginMode { csi("?6h") }   // origin mode is saved, the cursor is absolute
        setAttribute(buffer.savedAttr)
        if let designator = Self.designator(of: buffer.savedCharset) {
            esc("(" + designator)
        }
        esc("7")
        if buffer.savedCharset != nil { esc("(B") }
        if buffer.savedOriginMode { csi("?6l") }
        if !buffer.savedWraparound { csi("?7h") }
        if buffer.savedMarginMode { csi("?69l") }
        if buffer.savedReverseWraparound { csi("?45l") }
    }

    /// Rebuilds the flag stack from the bottom: set the oldest entry, then
    /// push each later entry and finally the current flags.
    private mutating func writeKeyboardFlags(_ state: Terminal.KeyboardModeState) {
        let chain = state.stack + [state.flags]
        guard chain.contains(where: { !$0.isEmpty }) || !state.stack.isEmpty else { return }
        csi("=\(chain[0].rawValue);1u")
        for flags in chain.dropFirst() {
            csi(">\(flags.rawValue)u")
        }
    }

    private mutating func writeMargins(of buffer: Buffer) {
        if terminal.marginMode {
            csi("?69h")
            if buffer.marginLeft != 0 || buffer.marginRight != terminal.cols - 1 {
                csi("\(buffer.marginLeft + 1);\(buffer.marginRight + 1)s")
            }
        }
        if buffer.scrollTop != 0 || buffer.scrollBottom != terminal.rows - 1 {
            csi("\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r")
        }
    }

    /// Positions the cursor. With withMode, also sets origin mode first so the
    /// position is relative to the margins as the application expects. A
    /// pending wrap (x == cols) is reproduced by printing the last cell again.
    private mutating func writeCursor(of buffer: Buffer, withMode: Bool = true) {
        let origin = withMode && terminal.originMode
        if origin { csi("?6h") }
        let rowBase = origin ? buffer.scrollTop : 0
        let colBase = origin && terminal.marginMode ? buffer.marginLeft : 0
        let x = min(buffer.x, terminal.cols)
        if x >= terminal.cols {
            let line = buffer.lines[buffer.yBase + buffer.y]
            var last = terminal.cols - 1
            while last > 0 && line.getWidth(index: last) == 0 { last -= 1 }
            csi("\(buffer.y - rowBase + 1);\(last - colBase + 1)H")
            let cell = line[last]
            setCellState(cell)
            bytes.append(contentsOf: Array((cell.code == 0 ? " " : cell.getText()).utf8))
        } else {
            csi("\(buffer.y - rowBase + 1);\(x - colBase + 1)H")
        }
    }

    // MARK: Terminal modes

    private mutating func writeTerminalModes() {
        let t = terminal
        func decset(_ mode: Int, _ on: Bool, default value: Bool = false) {
            guard on != value else { return }
            csi("?\(mode)" + (on ? "h" : "l"))
        }
        decset(1, t.applicationCursor)
        decset(4, t.smoothScroll)
        decset(5, t.reverseColors)
        decset(12, t.cursorBlink)
        decset(25, !t.cursorHidden, default: true)
        decset(40, t.allow80To132)
        decset(45, t.reverseWraparound)
        decset(66, t.applicationKeypad)
        decset(69, t.marginMode)
        decset(1004, t.sendFocus)
        decset(1007, t.alternateScrollMode, default: true)
        decset(2004, t.bracketedPasteMode)
        decset(SpecialDECPrivateMode.colorSchemeReports.rawValue, t.colorSchemeUpdatesEnabled)
        decset(SpecialDECPrivateMode.visibilityReports.rawValue, t.visibilityReportsEnabled)
        decset(SpecialDECPrivateMode.inBandSizeReports.rawValue, t.inBandSizeReportsEnabled)
        #if !SWIFTTERM_EMBEDDED
        decset(SpecialDECPrivateMode.kittyPasteEvents.rawValue, t.kittyPasteEventsEnabled)
        #endif
        decset(1243, t.bidiArrowKeySwap, default: t.options.initialBidiArrowKeySwap)
        switch t.mouseMode {
        case .off: break
        case .x10: csi("?9h")
        case .vt200: csi("?1000h")
        case .buttonEventTracking: csi("?1002h")
        case .anyEvent: csi("?1003h")
        }
        switch t.mouseProtocol {
        case .x10: break
        case .utf8: csi("?1005h")
        case .sgr: csi("?1006h")
        case .urxvt: csi("?1015h")
        case .sgrPixel: csi("?1016h")
        }
        if t.insertMode { csi("4h") }
        if t.lineFeedMode { csi("20h") }
        if t.options.cursorStyle != t.defaultCursorStyle {
            csi("\(t.options.cursorStyle.decscusrParameter) q")
        }
        writeTabStops()
        writeCharsets()
        if !t.iconTitle.isEmpty { osc("1;" + t.iconTitle) }
        if !t.terminalTitle.isEmpty { osc("2;" + t.terminalTitle) }
        if let directory = t.hostCurrentDirectory { osc("7;" + directory) }
        if let document = t.hostCurrentDocument { osc("6;" + document) }
        // Wraparound last: line writing and the pending wrap need it on.
        decset(7, t.wraparound, default: true)
        writeCurrentPrintState()
    }

    private mutating func writeTabStops() {
        let buffer = terminal.buffer
        let width = terminal.tabStopWidth
        let stops = buffer.tabStops
        let isDefault = stops.indices.allSatisfy { stops[$0] == ($0 % width == 0 && $0 != 0) || $0 == 0 }
        guard !isDefault else { return }
        csi("3g")
        for column in stops.indices where stops[column] {
            csi("\(buffer.y + 1);\(column + 1)H")
            esc("H")
        }
    }

    private mutating func writeCharsets() {
        let t = terminal
        let intermediates = ["(", ")", "*", "+"]
        for (index, charset) in t.gCharsets.enumerated() where index < intermediates.count {
            guard let charset, let designator = Self.designator(of: charset) else { continue }
            esc(intermediates[index] + designator)
        }
        switch t.gLevel {
        case 1: bytes.append(0x0E)
        case 2: esc("n")
        case 3: esc("o")
        default: break
        }
    }

    /// The designator byte for a charset table, from the known tables.
    private static func designator(of charset: [UInt8: String]?) -> String? {
        guard let charset, !charset.isEmpty else { return nil }
        for (key, table) in CharSets.all where table == charset {
            return String(UnicodeScalar(key))
        }
        return nil
    }

    /// The attribute, semantic role and hyperlink that the next printed
    /// character receives.
    private mutating func writeCurrentPrintState() {
        let t = terminal
        setAttribute(t.currentAttribute)
        let content = t.buffer.semanticContent
        if content != semantic { setSemantic(content) }
        let link = t.activeHyperlinkPayload
        if link != hyperlink {
            osc("8;" + (link ?? ";"))
            hyperlink = link
        }
    }

    // MARK: Output

    private mutating func csi(_ body: String) {
        bytes.append(0x1B)
        bytes.append(UInt8(ascii: "["))
        bytes.append(contentsOf: Array(body.utf8))
    }

    private mutating func esc(_ body: String) {
        bytes.append(0x1B)
        bytes.append(contentsOf: Array(body.utf8))
    }

    private mutating func osc(_ body: String) {
        bytes.append(0x1B)
        bytes.append(UInt8(ascii: "]"))
        bytes.append(contentsOf: Array(body.utf8))
        bytes.append(0x1B)
        bytes.append(UInt8(ascii: "\\"))
    }
}

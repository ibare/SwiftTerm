//
//  OffscreenDrawingTests.swift
//
//  Drawing the terminal into a bitmap (cacheDisplay, as a host does to take a
//  snapshot of its window) must carry the default background. On screen it
//  comes from the layer; in a bitmap only what the view paints is there.
//

#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct OffscreenDrawingTests {
    /// A host that paints itself, so a hole in the terminal shows through in its color.
    private final class PaintedHost: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }

    private func makeView(background: NSColor) -> (host: NSView, view: TerminalView) {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        view.setFrameSize(NSSize(
            width: view.cellDimension.width * 10,
            height: view.cellDimension.height * 4))
        let host = PaintedHost(frame: view.frame)
        host.addSubview(view)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return (host, view)
    }

    private func render(_ host: NSView, _ view: TerminalView) throws -> NSBitmapImageRep {
        view.frameTick()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func count(
        _ bitmap: NSBitmapImageRep,
        red: ClosedRange<CGFloat>,
        green: ClosedRange<CGFloat>,
        blue: ClosedRange<CGFloat>
    ) -> Int {
        var result = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.99 else {
                    continue
                }
                if red.contains(color.redComponent),
                   green.contains(color.greenComponent),
                   blue.contains(color.blueComponent) {
                    result += 1
                }
            }
        }
        return result
    }

    @Test func opaqueDefaultBackgroundReachesTheBitmap() throws {
        let (host, view) = makeView(background: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1))
        view.feed(text: "hello")
        let bitmap = try render(host, view)
        let pixels = bitmap.pixelsWide * bitmap.pixelsHigh

        // Nearly every pixel is the default background; none shows the host.
        let background = count(bitmap, red: 0...0.3, green: 0.1...0.4, blue: 0.4...0.7)
        #expect(background > pixels * 9 / 10)
        #expect(count(bitmap, red: 0.8...1, green: 0...0.4, blue: 0...0.4) == 0)
        // The text is still drawn over it.
        #expect(count(bitmap, red: 0.8...1, green: 0.8...1, blue: 0.8...1) > 0)
    }

    @Test func translucentDefaultBackgroundIsNotPaintedTwice() throws {
        // A translucent background is composited by the layer on screen; painting
        // it into the backing store as well would double it, so it stays cleared.
        let (host, view) = makeView(background: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 0.5))
        let bitmap = try render(host, view)
        #expect(count(bitmap, red: 0...0.3, green: 0.1...0.4, blue: 0.4...0.7) == 0)
    }
}
#endif

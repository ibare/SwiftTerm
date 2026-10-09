//
//  LinkRevealDrawingTests.swift
//
//  What the renderers draw while Command reveals links: an underline under a
//  link near the pointer and a translucent fill behind it, nothing while the
//  reveal waits on its delay, and nothing again once it has faded out. Both
//  renderers are checked, the Core Graphics one through cacheDisplay and the
//  Metal one through its rendered texture.
//

#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

#if canImport(MetalKit)
import Metal
#endif

@MainActor
@Suite(.serialized)
struct LinkRevealDrawingTests {
    /// Longer than the reveal's transition, so a frame drawn after it shows the
    /// settled state.
    private static let settle: Duration = .milliseconds(300)

    private func makeView(delay: TimeInterval) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        view.setFrameSize(NSSize(width: view.cellDimension.width * 24,
                                 height: view.cellDimension.height * 3))
        view.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        view.linkRevealStyle = LinkRevealStyle(color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                                               delay: delay)
        view.feed(text: "see docs/a.md here")
        return view
    }

    /// Holds Command with the pointer on the link's row.
    private func reveal(_ view: TerminalView) {
        view.linkRevealCommandPressed()
        view.linkRevealPointerMoved(to: CGPoint(x: 1, y: view.bounds.maxY - 1), row: 0)
    }

    private func renderCoreGraphics(_ view: TerminalView) throws -> NSBitmapImageRep {
        view.frameTick()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Pixels of `bitmap` whose sRGB components fall in the ranges.
    private func count(_ bitmap: NSBitmapImageRep, red: ClosedRange<CGFloat>, green: ClosedRange<CGFloat>,
                       blue: ClosedRange<CGFloat>) -> Int {
        var result = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if red.contains(color.redComponent), green.contains(color.greenComponent),
                   blue.contains(color.blueComponent) {
                    result += 1
                }
            }
        }
        return result
    }

    private func underlinePixels(_ bitmap: NSBitmapImageRep) -> Int {
        count(bitmap, red: 0...0.15, green: 0.85...1, blue: 0...0.15)
    }

    private func fillPixels(_ bitmap: NSBitmapImageRep) -> Int {
        // The fill is the reveal color at 20% over black.
        count(bitmap, red: 0...0.03, green: 0.12...0.3, blue: 0...0.03)
    }

    @Test func coreGraphicsDrawsUnderlineAndFill() async throws {
        let view = makeView(delay: 0)
        reveal(view)
        try await Task.sleep(for: Self.settle)
        let bitmap = try renderCoreGraphics(view)
        #expect(underlinePixels(bitmap) > 0)
        #expect(fillPixels(bitmap) > 0)
        view.endLinkReveal()
    }

    @Test func coreGraphicsDrawsNothingWhileTheDelayRuns() async throws {
        let view = makeView(delay: 60)
        reveal(view)
        try await Task.sleep(for: Self.settle)
        let bitmap = try renderCoreGraphics(view)
        #expect(underlinePixels(bitmap) == 0)
        #expect(fillPixels(bitmap) == 0)
        view.endLinkReveal()
    }

    @Test func coreGraphicsClearsTheRevealOnceReleased() async throws {
        let view = makeView(delay: 0)
        reveal(view)
        try await Task.sleep(for: Self.settle)
        _ = try renderCoreGraphics(view)
        view.endLinkReveal()
        try await Task.sleep(for: Self.settle)
        let bitmap = try renderCoreGraphics(view)
        #expect(underlinePixels(bitmap) == 0)
        #expect(fillPixels(bitmap) == 0)
    }

#if canImport(MetalKit)
    /// Renders `view` through the Metal renderer and returns BGRA bytes, or nil
    /// when this machine cannot render offscreen.
    private func renderMetal(_ view: TerminalView) -> (bytes: [UInt8], width: Int)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        // The renderer lays the frame out at the view's scale; a view outside a
        // window would otherwise use the main screen's and draw past the target.
        view.metalScaleFactorOverride = 1
        let size = view.bounds.size
        let target = TerminalMetalLayerView(frame: CGRect(origin: .zero, size: size))
        target.renderDevice = device
        target.metalLayer.framebufferOnly = false
        target.renderContentsScale = 1
        target.renderDrawableSize = size
        guard let renderer = try? MetalTerminalRenderer(target: target) else { return nil }
        renderer.waitForCompletionAfterCommit = true
        renderer.capturesRenderedTexture = true
        guard view.renderSnapshotForMetal(renderer: renderer, target: target),
              let texture = renderer.lastRenderedTexture,
              texture.width > 0, texture.height > 0 else { return nil }
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return (bytes, texture.width)
    }

    private func count(_ bytes: [UInt8], red: ClosedRange<UInt8>, green: ClosedRange<UInt8>,
                       blue: ClosedRange<UInt8>) -> Int {
        stride(from: 0, to: bytes.count, by: 4).filter { index in
            blue.contains(bytes[index]) && green.contains(bytes[index + 1]) && red.contains(bytes[index + 2])
        }.count
    }

    /// The text itself, so a frame laid out off the target cannot pass for an
    /// empty reveal.
    private func textPixels(_ bytes: [UInt8]) -> Int {
        count(bytes, red: 200...255, green: 200...255, blue: 200...255)
    }

    @Test func metalDrawsUnderlineAndFill() async throws {
        let view = makeView(delay: 0)
        reveal(view)
        try await Task.sleep(for: Self.settle)
        guard let rendered = renderMetal(view) else { return }
        #expect(textPixels(rendered.bytes) > 0)
        #expect(count(rendered.bytes, red: 0...38, green: 217...255, blue: 0...38) > 0)
        #expect(count(rendered.bytes, red: 0...8, green: 30...77, blue: 0...8) > 0)
        view.endLinkReveal()
    }

    @Test func metalDrawsNothingWhileTheDelayRuns() async throws {
        let view = makeView(delay: 60)
        reveal(view)
        try await Task.sleep(for: Self.settle)
        guard let rendered = renderMetal(view) else { return }
        #expect(textPixels(rendered.bytes) > 0)
        #expect(count(rendered.bytes, red: 0...38, green: 217...255, blue: 0...38) == 0)
        view.endLinkReveal()
    }
#endif
}
#endif

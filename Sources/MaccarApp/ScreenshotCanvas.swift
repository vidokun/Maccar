import AppKit

/// Low-level offscreen rasterisation for `ScreenshotExporter`: builds Retina bitmaps whose
/// logical size matches the drawn point size, and encodes them as PNG. Nothing here touches
/// the screen, so no Screen Recording or Accessibility permission is ever requested.
@MainActor
enum ScreenshotCanvas {
    static let scale: CGFloat = 2

    /// A bitmap whose logical size is `size`, so one drawn point covers two pixels.
    private static func bitmap(for size: NSSize) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        return rep
    }

    /// Captures a view hierarchy as a 2x bitmap without going through the window server.
    /// `cacheDisplay` needs an existing backing store and a display cycle, both of which a view
    /// that was never shown lacks; a PDF replay of the tree's own drawing has neither requirement.
    /// The page is drawn at its own scale: the context already maps one point to `scale` pixels
    /// through `rep.size`, and a flipped view's PDF is stored upright, so neither a manual scale
    /// nor a flip correction belongs here.
    static func snapshot(_ view: NSView, appearance: NSAppearance? = nil) -> NSImage {
        let bounds = view.bounds
        let image = NSImage(size: bounds.size)
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmap(for: bounds.size),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }

        if let appearance { applyAppearance(appearance, to: view) }
        view.layoutSubtreeIfNeeded()
        guard let page = NSPDFImageRep(data: view.dataWithPDF(inside: bounds)) else { return image }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        page.draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()

        image.addRepresentation(rep)
        return image
    }

    /// Pins `appearance` on the view and every descendant, so `effectiveAppearance` cannot
    /// fall back to the machine's theme partway down the tree.
    static func applyAppearance(_ appearance: NSAppearance, to view: NSView) {
        view.appearance = appearance
        view.subviews.forEach { applyAppearance(appearance, to: $0) }
    }

    /// Draws `draw` into a fresh 2x canvas; the closure receives the full point-sized bounds.
    /// No manual scale: `rep.size` already makes one drawn point cover `scale` pixels.
    static func render(_ size: NSSize, draw: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        guard let rep = bitmap(for: size), let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    static func write(_ image: NSImage, named name: String, to directoryURL: URL) throws {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let png = rep.representation(using: .png, properties: [:]) else {
            throw ScreenshotExportError.encodingFailed(name)
        }
        try png.write(to: directoryURL.appendingPathComponent(name))
    }
}

enum ScreenshotExportError: LocalizedError {
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let name): return "Could not encode screenshot \(name) as PNG."
        }
    }
}

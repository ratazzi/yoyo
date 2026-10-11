import AppKit

@main
struct RenderAppIcons {
    static func render(size: Int, menu: Bool, to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "IconRenderer", code: 1)
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        if !menu {
            guard let source = NSImage(contentsOfFile: "Resources/Artwork/DockFlipClock-source.png") else {
                throw NSError(domain: "IconRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing Dock flip-clock artwork"])
            }
            let width = CGFloat(size)
            let tile = NSRect(x: width * 0.07, y: width * 0.07, width: width * 0.86, height: width * 0.86)
            let mask = NSBezierPath(roundedRect: tile, xRadius: width * 0.19, yRadius: width * 0.19)
            mask.addClip()
            NSColor(calibratedRed: 0.965, green: 0.953, blue: 0.925, alpha: 1).setFill(); tile.fill()
            // Source-specific trim enlarges the clock without enlarging the paper tile.
            // The untouched full-resolution source is preserved in Resources/Artwork.
            let crop = NSRect(x: source.size.width * 0.13, y: source.size.height * 0.13,
                              width: source.size.width * 0.74, height: source.size.height * 0.74)
            source.draw(in: tile, from: crop, operation: .sourceOver, fraction: 1)
        } else {
            TimezoneArtwork.icon(in: bounds, menu: menu)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "IconRenderer", code: 2) }
        try data.write(to: url)
    }
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon-assets")
        let iconset = output.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            try render(size: size, menu: false, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
            try render(size: size * 2, menu: false, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
        try render(size: 1024, menu: false, to: output.appendingPathComponent("AppIcon.png"))
        try render(size: 64, menu: true, to: output.appendingPathComponent("MenuBarTemplate.png"))
        print(output.path)
    }
}

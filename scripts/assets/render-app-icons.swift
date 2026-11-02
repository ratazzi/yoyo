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
        TimezoneArtwork.icon(in: bounds, menu: menu)
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

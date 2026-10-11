import AppKit

enum TimezoneArtwork {
    static func tile(in bounds: NSRect) {
        let size = min(bounds.width, bounds.height)
        let tile = NSRect(x: size * 0.07, y: size * 0.07, width: size * 0.86, height: size * 0.86)
        let shape = NSBezierPath(roundedRect: tile, xRadius: size * 0.19, yRadius: size * 0.19)
        NSColor(calibratedRed: 0.965, green: 0.953, blue: 0.925, alpha: 1).setFill(); shape.fill()
    }

    static func globe(center: NSPoint, radius: CGFloat, color: NSColor, width: CGFloat) {
        color.setStroke()
        let outline = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        outline.lineWidth = width; outline.stroke()
        let meridian = NSBezierPath(ovalIn: NSRect(x: center.x - radius * 0.44, y: center.y - radius, width: radius * 0.88, height: radius * 2))
        meridian.lineWidth = width; meridian.stroke()
        for offset in [-0.36, 0.36] {
            let line = NSBezierPath(); let y = center.y + radius * offset
            line.move(to: NSPoint(x: center.x - radius * 0.92, y: y))
            line.line(to: NSPoint(x: center.x + radius * 0.92, y: y))
            line.lineWidth = width; line.stroke()
        }
    }

    static func icon(in bounds: NSRect, menu: Bool = false) {
        let size = min(bounds.width, bounds.height)
        if !menu { tile(in: bounds) }
        let color: NSColor = menu ? .black : .white
        globe(center: NSPoint(x: size * (menu ? 0.42 : 0.45), y: size * 0.56),
              radius: size * (menu ? 0.35 : 0.245), color: color, width: size * (menu ? 0.035 : 0.024))
        let center = NSPoint(x: size * (menu ? 0.73 : 0.66), y: size * (menu ? 0.25 : 0.33))
        let radius = size * (menu ? 0.18 : 0.155)
        let clock = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        if !menu { NSColor.white.setFill(); clock.fill() }
        color.setStroke(); clock.lineWidth = size * (menu ? 0.035 : 0.015); clock.stroke()
        (menu ? NSColor.black : NSColor(calibratedRed: 0.14, green: 0.31, blue: 0.75, alpha: 1)).setStroke()
        let hands = NSBezierPath(); hands.move(to: NSPoint(x: center.x, y: center.y + radius * 0.6))
        hands.line(to: center); hands.line(to: NSPoint(x: center.x + radius * 0.45, y: center.y - radius * 0.2))
        hands.lineWidth = size * (menu ? 0.035 : 0.022); hands.lineCapStyle = .round; hands.lineJoinStyle = .round; hands.stroke()
    }
}

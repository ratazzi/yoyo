import AppKit

enum TimezoneArtwork {
    // A small integer grid keeps the silhouette and custom digits reproducible.
    // Coordinates use AppKit's bottom-left origin.
    static func flipClock(in bounds: NSRect, digits: String = "0941") {
        tile(in: bounds)
        let size = min(bounds.width, bounds.height)
        let scale = size / 64
        let origin = NSPoint(x: bounds.midX - size / 2, y: bounds.midY - size / 2)
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: NSColor) {
            color.setFill()
            NSRect(x: origin.x + x * scale, y: origin.y + y * scale,
                   width: width * scale, height: height * scale).fill()
        }
        let charcoal = NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.19, alpha: 1)
        let lower = NSColor(calibratedRed: 0.21, green: 0.22, blue: 0.22, alpha: 1)
        let ink = NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.90, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        // Stepped corners, two flip panels and a low pedestal.
        rect(29, 20, 6, 4, charcoal)
        rect(23, 19, 18, 2, charcoal)
        rect(20, 18, 24, 1, charcoal)
        for x: CGFloat in [6, 34] {
            rect(x + 2, 23, 20, 22, charcoal)
            rect(x, 25, 24, 18, charcoal)
            rect(x + 1, 24, 22, 10, lower)
        }
        let glyphs: [Character: [String]] = [
            "0": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
            "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
            "2": ["01110", "11011", "00011", "00110", "01100", "11000", "11111"],
            "3": ["11110", "00011", "00011", "01110", "00011", "00011", "11110"],
            "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
            "5": ["11111", "11000", "11000", "11110", "00011", "00011", "11110"],
            "6": ["01110", "11000", "11000", "11110", "11011", "11011", "01110"],
            "7": ["11111", "00011", "00110", "00110", "01100", "01100", "01100"],
            "8": ["01110", "11011", "11011", "01110", "11011", "11011", "01110"],
            "9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"]
        ]
        for (digit, x) in zip(digits.prefix(4), [8, 19, 36, 47]) {
            guard let rows = glyphs[digit] else { continue }
            for (row, cells) in rows.enumerated() {
                for (column, cell) in cells.enumerated() where cell == "1" {
                    rect(CGFloat(x + column * 2), CGFloat(39 - row * 2), 2, 2, ink)
                }
            }
        }
        rect(31, 36, 2, 2, charcoal); rect(31, 30, 2, 2, charcoal)
        for x: CGFloat in [6, 34] { rect(x, 33.5, 24, 0.5, .black) }
        let hinge = NSColor(calibratedWhite: 0.40, alpha: 1)
        rect(5, 32, 1.5, 4, hinge); rect(57.5, 32, 1.5, 4, hinge)
        NSGraphicsContext.restoreGraphicsState()
    }

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
        if !menu { flipClock(in: bounds); return }
        let size = min(bounds.width, bounds.height)
        globe(center: NSPoint(x: size * 0.42, y: size * 0.56),
              radius: size * 0.35, color: .black, width: size * 0.035)
        let center = NSPoint(x: size * 0.73, y: size * 0.25)
        let radius = size * 0.18
        let clock = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSColor.black.setStroke(); clock.lineWidth = size * 0.035; clock.stroke()
        let hands = NSBezierPath(); hands.move(to: NSPoint(x: center.x, y: center.y + radius * 0.6))
        hands.line(to: center); hands.line(to: NSPoint(x: center.x + radius * 0.45, y: center.y - radius * 0.2))
        hands.lineWidth = size * 0.035; hands.lineCapStyle = .round; hands.lineJoinStyle = .round; hands.stroke()
    }
}

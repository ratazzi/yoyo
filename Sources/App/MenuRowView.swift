import AppKit

@MainActor
final class MenuRowSelection: NSObject, NSMenuDelegate {
    private(set) weak var selected: MenuRowView?

    func select(_ row: MenuRowView?) {
        guard selected !== row else { return }
        let previous = selected
        selected = row
        previous?.needsDisplay = true; row?.needsDisplay = true
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { select(item?.view as? MenuRowView) }
    func menuDidClose(_ menu: NSMenu) { select(nil) }
}

@MainActor
final class MenuRowView: NSView {
    enum Detail {
        case program(zone: String, running: Bool)
        case timeZone(time: String, offset: String)
    }

    weak var item: NSMenuItem?
    private let name: String
    private let detail: Detail
    private let icon: NSImage?
    private let selection: MenuRowSelection

    init(name: String, detail: Detail, icon: NSImage?, selection: MenuRowSelection? = nil) {
        self.name = name; self.detail = detail; self.icon = icon
        self.selection = selection ?? MenuRowSelection()
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        autoresizingMask = [.width]
        // Keep transparent redraws in this row's layer, above the menu's material.
        wantsLayer = true
        layer?.needsDisplayOnBoundsChange = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        switch detail {
        case let .program(zone, running): setAccessibilityLabel("\(name), \(zone)" + (running ? ", Running" : ""))
        case let .timeZone(time, offset): setAccessibilityLabel("\(name), \(time), \(offset)")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        // Erase the previous highlight before drawing transparent menu content.
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        let highlighted = selection.selected === self
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
        let primary = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let secondary = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor
        // Both sections share these columns and the actual row's right edge.
        let detailStart = bounds.maxX - 164
        func text(_ value: String, x: CGFloat, width: CGFloat, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle; paragraph.alignment = alignment
            let height = (value as NSString).size(withAttributes: [.font: font]).height
            (value as NSString).draw(in: NSRect(x: x, y: bounds.midY - height / 2, width: max(0, width), height: height),
                withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        if let icon {
            let size: CGFloat = icon.isTemplate ? 20 : 24
            let rect = NSRect(x: 37 - size / 2, y: bounds.midY - size / 2, width: size, height: size)
            if icon.isTemplate {
                let tinted = NSImage(size: rect.size, flipped: false) { imageBounds in
                    icon.draw(in: imageBounds)
                    primary.setFill(); imageBounds.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: rect)
            } else { icon.draw(in: rect) }
        }
        text(name, x: 52, width: detailStart - 70, font: .menuFont(ofSize: 13), color: primary)
        switch detail {
        case let .program(zone, running):
            text(zone, x: detailStart, width: 130, font: .menuFont(ofSize: 13), color: secondary)
            if running {
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 20, y: bounds.midY - 3, width: 6, height: 6)).fill()
            }
        case let .timeZone(time, offset):
            text(time, x: detailStart, width: 74, font: .monospacedSystemFont(ofSize: 13, weight: .medium), color: primary)
            text(offset, x: bounds.maxX - 80, width: 66, font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: secondary, alignment: .right)
            if item?.state == .on {
                text("✓", x: 5, width: 15, font: .systemFont(ofSize: 14, weight: .medium), color: primary)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { selection.select(self) }
    override func mouseExited(with event: NSEvent) {
        if selection.selected === self { selection.select(nil) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil && selection.selected === self { selection.select(nil) }
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { selection.select(self) }
    override func mouseDragged(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { selection.select(self) }
        else if selection.selected === self { selection.select(nil) }
    }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }
    override func accessibilityPerformPress() -> Bool { activate() }

    @discardableResult
    private func activate() -> Bool {
        guard let item, let menu = item.menu else { return false }
        if let submenu = item.submenu {
            submenu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.maxY), in: self)
            return true
        }
        let index = menu.index(of: item)
        guard index >= 0 else { return false }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
        return true
    }
}

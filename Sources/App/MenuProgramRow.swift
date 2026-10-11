import AppKit

@MainActor
final class MenuRowSelection: NSObject, NSMenuDelegate {
    private(set) weak var selected: MenuProgramRow?

    func select(_ row: MenuProgramRow?) {
        guard selected !== row else { return }
        let previous = selected
        selected = row
        previous?.needsDisplay = true; row?.needsDisplay = true
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { select(item?.view as? MenuProgramRow) }
    func menuDidClose(_ menu: NSMenu) { select(nil) }
}

@MainActor
final class MenuProgramRow: NSView {
    weak var item: NSMenuItem?
    private let title: String
    private let icon: NSImage?
    private let running: Bool
    private let selection: MenuRowSelection

    init(title: String, icon: NSImage?, running: Bool, selection: MenuRowSelection? = nil) {
        self.title = title; self.icon = icon; self.running = running
        self.selection = selection ?? MenuRowSelection()
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        autoresizingMask = [.width]
        // Keep transparent redraws in this row's layer, above the menu's material.
        wantsLayer = true
        layer?.needsDisplayOnBoundsChange = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title + (running ? ", Running" : ""))
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
        icon?.draw(in: NSRect(x: 20, y: bounds.midY - 12, width: 24, height: 24))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let font = NSFont.menuFont(ofSize: 13)
        let height = (title as NSString).size(withAttributes: [.font: font]).height
        (title as NSString).draw(in: NSRect(x: 50, y: bounds.midY - height / 2,
                                           width: max(0, bounds.width - 80), height: height), withAttributes: [
            .font: font, .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        if running {
            NSColor.systemGreen.setFill()
            // Anchor to the actual row width, including width added by other menu sections.
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 20, y: bounds.midY - 3, width: 6, height: 6)).fill()
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
        let index = menu.index(of: item)
        guard index >= 0 else { return false }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
        return true
    }
}

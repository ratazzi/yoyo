import AppKit

@MainActor
final class BadgeFixtureController: NSObject, NSWindowDelegate, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 520, height: 280),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    private let label = NSTextField(wrappingLabelWithString: "")

    override init() {
        super.init()
        window.title = "Yoyo — Badge Test"; window.isReleasedWhenClosed = false; window.delegate = self
        label.font = .systemFont(ofSize: 15)
        label.frame = NSRect(x: 24, y: 24, width: 472, height: 232); label.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(label)
        update()
    }

    func windowDidMove(_ notification: Notification) { update() }
    func windowDidResize(_ notification: Notification) { update() }
    func update() {
        let frame = window.frame
        label.stringValue = "Window Badge Test\n\nActual process time zone: \(TimeZone.current.identifier)\n\nWindow frame: x=\(Int(frame.minX)), y=\(Int(frame.minY)), w=\(Int(frame.width)), h=\(Int(frame.height))\n\nUse the Test menu to check edges, maximization and full screen."
    }

    @objc func test(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String, let screen = window.screen ?? NSScreen.main else { return }
        NSApp.activate(ignoringOtherApps: true)
        let target = action == "Other Display" ? NSScreen.screens.first(where: { $0 !== screen }) ?? screen : screen
        let visible = target.visibleFrame
        if action == "Full Screen" { window.toggleFullScreen(nil); return }
        if action == "Minimize" { window.miniaturize(nil); return }
        var frame = CGRect(x: visible.midX - 260, y: visible.midY - 156, width: 520, height: 312)
        switch action {
        case "Top Edge": frame.origin.y = visible.maxY - frame.height
        case "Right Edge": frame.origin.x = visible.maxX - frame.width
        case "Bottom Edge": frame.origin.y = visible.minY
        case "Left Edge": frame.origin.x = visible.minX
        case "Top-Right Corner": frame.origin = CGPoint(x: visible.maxX - frame.width, y: visible.maxY - frame.height)
        case "Maximize": frame = visible
        default: break
        }
        window.deminiaturize(nil); window.setFrame(frame, display: true); window.makeKeyAndOrderFront(nil)
        update()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil); sender.activate(ignoringOtherApps: true); return true
    }
}

@main
struct BadgeWindowFixture {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let controller = BadgeFixtureController(); app.delegate = controller
        let menu = NSMenu(); let parent = NSMenuItem(); let actions = NSMenu()
        let quit = NSMenuItem(title: "Quit Window Badge Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app; actions.addItem(quit); parent.submenu = actions; menu.addItem(parent)
        let testMenu = NSMenu(title: "Test"); let testItem = NSMenuItem(title: "Test", action: nil, keyEquivalent: "")
        for title in ["Center Window", "Other Display", "Top Edge", "Right Edge", "Bottom Edge", "Left Edge", "Top-Right Corner", "Maximize", "Full Screen", "Minimize"] {
            let item = NSMenuItem(title: title, action: #selector(BadgeFixtureController.test), keyEquivalent: "")
            item.target = controller; item.representedObject = title; testMenu.addItem(item)
        }
        testItem.submenu = testMenu; menu.addItem(testItem); app.mainMenu = menu
        controller.window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        withExtendedLifetime(controller) { app.run() }
    }
}

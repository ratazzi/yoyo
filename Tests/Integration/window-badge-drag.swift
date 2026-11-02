import AppKit

@main
enum WindowBadgeMotionTest {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 360, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Yoyo motion verification"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 330, height: 3000))
        text.string = String(repeating: "Scroll and select this test text.\n", count: 100)
        text.isEditable = false; scroll.documentView = text
        window.contentView?.addSubview(scroll)
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let initialFrame = window.frame
        let prefix = "\(getpid()):"
        var failed = false
        let root = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        func check(moving: Bool, phase: String) {
            let value = (try? Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("build/state/window-badge-diagnostics.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let tracked = (value?["tracked_windows"] as? [String] ?? []).contains { $0.hasPrefix(prefix) }
            let suppressed = (value?["moving_windows"] as? [String] ?? []).contains { $0.hasPrefix(prefix) }
            let badges = value?["debug_badges"] as? [[String: Any]] ?? []
            let visible = badges.contains { ($0["identity"] as? String)?.hasPrefix(prefix) == true }
            if !tracked || suppressed != moving || (moving && visible) || value?["status"] as? String == "Hidden while dragging" {
                failed = true; print("FAIL \(phase): tracked=\(tracked), moving=\(suppressed), visible=\(visible)")
            } else { print("\(phase): PASS") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            check(moving: false, phase: "Stable window is tracked")
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0, wheel3: 0)
            if let event, let wheel = NSEvent(cgEvent: event) { scroll.scrollWheel(with: wheel) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            if scroll.contentView.bounds.origin.y == 0 || window.frame != initialFrame {
                failed = true; print("FAIL: scroll must move document content without moving the window")
            }
            check(moving: false, phase: "Real content scrolling does not suppress badges")
            text.setSelectedRange(NSRange(location: 5, length: 25))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
            check(moving: false, phase: "Text selection does not suppress badges")
        }
        for step in 1...20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(step) * 0.08) {
                window.setFrameOrigin(CGPoint(x: initialFrame.minX + Double(step) * 8, y: initialFrame.minY))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { check(moving: true, phase: "Actual window movement suppresses its badge") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { check(moving: true, phase: "Continued window movement stays suppressed") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.8) {
            check(moving: false, phase: "Stable geometry resumes badge evaluation")
            window.orderOut(nil); exit(failed ? 1 : 0)
        }
        withExtendedLifetime(window) { app.run() }
    }
}

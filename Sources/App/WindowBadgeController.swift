import AppKit
import ApplicationServices
import Combine

@MainActor
final class WindowBadgeController {
    private let store: AppStore
    private let panel = WindowBadgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    private let clock = ClockPresentationFactory()
    private let queue = DispatchQueue(label: "dev.timezone.lab.window-badge", qos: .utility)
    private var timer: Timer?
    private var previewSubscription: AnyCancellable?
    private var identity = ""
    private var lastQuery = Date.distantPast
    private var process: WindowBadgeProcess?
    private var inFlight = false
    private var previewUntil = Date.distantPast
    private let diagnostics: URL?
    private var lastDiagnostic: Data?

    init(store: AppStore) {
        self.store = store
        diagnostics = ProcessInfo.processInfo.environment["TIMEZONE_LAB_WINDOW_BADGE_DIAGNOSTICS"] == "1"
            ? store.stateDirectory.appendingPathComponent("window-badge-diagnostics.json") : nil
        panel.title = "Timezone Lab Window Badge"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .popover; background.blendingMode = .behindWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 12; background.layer?.masksToBounds = true
        panel.contentView = background
        let icon = NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: "Time Zone")!)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(icon); background.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12), icon.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10)
        ])
        previewSubscription = NotificationCenter.default.publisher(for: .init("PreviewWindowBadge")).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.preview() }
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    private func preview() {
        guard let window = NSApp.keyWindow, window !== panel else { return }
        previewUntil = Date().addingTimeInterval(5)
        show(zone: TimeZone(identifier: "Asia/Tokyo")!, window: window.frame, preview: true)
    }

    private func tick() {
        if previewUntil > Date() {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            previewUntil = .distantPast
        }
        guard store.displayPreferences.showWindowBadge else { hide("Off"); return }
        guard AXIsProcessTrusted() else { hide("Accessibility Access Required"); return }
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleURL?.pathExtension.lowercased() == "app",
              let executable = app.executableURL?.resolvingSymlinksInPath().path,
              let launchDate = app.launchDate else { hide("No affected app in front"); return }
        let pid = app.processIdentifier
        let key = "\(pid):\(launchDate.timeIntervalSince1970):\(executable)"
        if identity != key {
            identity = key; process = nil; lastQuery = .distantPast
            hide("Checking active app")
        }
        guard !inFlight else { return }
        inFlight = true
        let query = Date().timeIntervalSince(lastQuery) >= 2
        if query { lastQuery = Date() }
        let cached = process
        let socket = store.stateDirectory.appendingPathComponent("control.sock").path
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        queue.async { [weak self] in
            let observed: WindowBadgeProcess?
            if query {
                let response = TZControl(socket, ["command": "process", "pid": Int(pid)])
                let data = (response?["process"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                observed = data.flatMap { try? JSONDecoder().decode(WindowBadgeProcess.self, from: $0) }
            } else { observed = cached }
            let frame = Self.focusedWindow(pid: pid, desktopTop: desktopTop)
            Task { @MainActor in
                guard let self else { return }
                self.inFlight = false
                guard self.identity == key, self.store.displayPreferences.showWindowBadge,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      NSWorkspace.shared.frontmostApplication?.launchDate == launchDate, !app.isTerminated else { return }
                self.process = observed
                guard let zone = observed?.confirmedZone(pid: Int(pid), executable: executable, launchedAt: launchDate.timeIntervalSince1970) else {
                    self.hide("No confirmed injected time zone"); return
                }
                var policy = PolicyDocument(); policy.default_mode = "fixed"; policy.default_zone = zone.identifier
                if self.clock.make(policy: policy, preferences: self.store.displayPreferences).matchesSystem {
                    self.hide("Time zone matches the system"); return
                }
                guard let frame else { self.hide("Window position unavailable or full screen"); return }
                self.show(zone: zone, window: frame)
            }
        }
    }

    private func show(zone: TimeZone, window: CGRect, preview: Bool = false) {
        var policy = PolicyDocument(); policy.default_mode = "fixed"; policy.default_zone = zone.identifier
        let city = clock.make(policy: policy, preferences: store.displayPreferences).city
        let title = (preview ? "Preview · " : "") + city
        let offset = MenuTimeZone.offset(for: zone, at: Date())
        let text = NSMutableAttributedString(string: title + "  ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: offset, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
        let size = CGSize(width: ceil(text.size().width) + 38, height: 24)
        guard let frame = WindowBadgePlacement.frame(window: window, size: size, screens: NSScreen.screens.map(\.visibleFrame)) else {
            hide("Hidden — no space outside the window"); return
        }
        label.attributedStringValue = text
        label.setAccessibilityLabel("\(city), UTC\(offset)" + (preview ? ", Preview" : ""))
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        status(preview ? "Preview" : "\(city) \(offset)")
        diagnose(window: window)
    }

    private func hide(_ value: String) { if panel.isVisible { panel.orderOut(nil) }; status(value); diagnose() }
    private func status(_ value: String) { if store.windowBadgeStatus != value { store.windowBadgeStatus = value } }

    private func diagnose(window: CGRect? = nil) {
        guard let diagnostics else { return }
        func rect(_ value: CGRect) -> [String: Double] {
            ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        var state: [String: Any] = ["visible": panel.isVisible, "status": store.windowBadgeStatus,
            "frontmost_pid": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),
            "mouse_passthrough": panel.ignoresMouseEvents, "is_key_window": panel.isKeyWindow,
            "accessibility_trusted": AXIsProcessTrusted()]
        state["screens"] = NSScreen.screens.map { rect($0.visibleFrame) }
        if panel.isVisible { state["badge"] = rect(panel.frame); state["text"] = label.stringValue }
        if let window { state["window"] = rect(window) }
        if let process { state["process_pid"] = process.pid; state["confirmed_zone"] = process.zone; state["hooks_loaded"] = process.loaded }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), data != lastDiagnostic else { return }
        lastDiagnostic = data
        try? data.write(to: diagnostics, options: .atomic)
    }

    nonisolated private static func focusedWindow(pid: pid_t, desktopTop: CGFloat) -> CGRect? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        guard let raw = attribute(application, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.08)
        if (attribute(window, kAXMinimizedAttribute) as? Bool) == true || (attribute(window, "AXFullScreen") as? Bool) == true { return nil }
        guard let point = attribute(window, kAXPositionAttribute), CFGetTypeID(point) == AXValueGetTypeID(),
              let extent = attribute(window, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(point as! AXValue, .cgPoint, &position), AXValueGetValue(extent as! AXValue, .cgSize, &size) else { return nil }
        // Do not follow an AX window left on another Space. Read only PID, layer and bounds.
        let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard visible.contains(where: { value in
            guard value[kCGWindowOwnerPID as String] as? Int == Int(pid), value[kCGWindowLayer as String] as? Int == 0,
                  let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return abs(rect.minX - position.x) < 4 && abs(rect.minY - position.y) < 4 &&
                abs(rect.width - size.width) < 4 && abs(rect.height - size.height) < 4
        }) else { return nil }
        return CGRect(x: position.x, y: desktopTop - position.y - size.height, width: size.width, height: size.height)
    }
}

private final class WindowBadgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

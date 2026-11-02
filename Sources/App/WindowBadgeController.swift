import AppKit
import ApplicationServices
import Combine

@MainActor
final class WindowBadgeController {
    private let store: AppStore
    private let overlay = WindowBadgeOverlay()
    private var panel: WindowBadgePanel { overlay.panel }
    private var label: NSTextField { overlay.label }
    private let clock = ClockPresentationFactory()
    private let queue = DispatchQueue(label: "yoyo.hola.ac.window-badge", qos: .utility)
    private var timer: Timer?
    private var previewSubscription: AnyCancellable?
    private var identity = ""
    private var lastQuery = Date.distantPast
    private var process: WindowBadgeProcess?
    private var inFlight = false
    private var previewUntil = Date.distantPast
    private let diagnostics: URL?
    private var lastDiagnostic: Data?
    private var debugWindows = WindowBadgeWindows()
    private var debugOverlays: [String: WindowBadgeOverlay] = [:]
    private var debugProcesses: [String: WindowBadgeProcess] = [:]
    private var debugLastQuery = Date.distantPast
    private var debugInFlight = false
    private var debugOrder: [String] = []
    private var motion = WindowBadgeMotion()
    private var motionTargets: [UInt32: WindowBadgeWindow] = [:]
    private var motionTimer: Timer?
    private var focusedMotionIdentity: String?
    // Fresh NSRunningApplication instances resolve properties through synchronous LaunchServices XPC.
    private var applications: (all: [pid_t: NSRunningApplication], prohibited: Set<pid_t>)?
    private var applicationsSubscription: AnyCancellable?

    init(store: AppStore) {
        self.store = store
        diagnostics = ProcessInfo.processInfo.environment["TIMEZONE_LAB_WINDOW_BADGE_DIAGNOSTICS"] == "1"
            ? store.stateDirectory.appendingPathComponent("window-badge-diagnostics.json") : nil
        previewSubscription = NotificationCenter.default.publisher(for: .init("PreviewWindowBadge")).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.preview() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        applicationsSubscription = workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applications = nil } }
        let motionTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleWindowMotion() }
        }
        self.motionTimer = motionTimer; RunLoop.main.add(motionTimer, forMode: .common)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    private func trackMotion(_ windows: [WindowBadgeWindow]) {
        motionTargets = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        motion.update(Dictionary(windows.map { ($0.identity, $0.frame) }, uniquingKeysWith: { first, _ in first }),
            at: ProcessInfo.processInfo.systemUptime)
    }

    private func sampleWindowMotion() {
        guard !motionTargets.isEmpty else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let rows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var frames: [String: CGRect] = [:]
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? NSNumber, let target = motionTargets[id.uint32Value],
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            frames[target.identity] = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        let now = ProcessInfo.processInfo.systemUptime
        motion.update(frames, at: now)
        for target in motionTargets.values where frames[target.identity] == nil || motion.isSuppressed(target.identity, at: now) {
            debugOverlays[target.identity]?.panel.orderOut(nil)
            if focusedMotionIdentity == target.identity { panel.orderOut(nil) }
        }
        diagnose()
    }

    private func preview() {
        guard let window = NSApp.keyWindow, window !== panel else { return }
        clearDebugOverlays()
        previewUntil = Date().addingTimeInterval(5)
        show(zone: TimeZone(identifier: "Asia/Tokyo")!, window: window.frame, preview: true)
    }

    private func tick() {
        if previewUntil > Date() {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            previewUntil = .distantPast
        }
        let force = store.displayPreferences.forceWindowBadge
        if force { tickDebug(); return }
        clearDebugOverlays()
        guard store.displayPreferences.showWindowBadge else { trackMotion([]); hide("Off"); return }
        guard AXIsProcessTrusted() else { hide("Accessibility Access Required"); return }
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleURL?.pathExtension.lowercased() == "app",
              let executable = app.executableURL?.resolvingSymlinksInPath().path,
              let launchDate = app.launchDate else { hide("No affected app in front"); return }
        let pid = app.processIdentifier
        let key = "\(pid):\(launchDate.timeIntervalSince1970):\(executable)"
        if identity != key {
            identity = key; process = nil; lastQuery = .distantPast; trackMotion([])
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
                      !self.store.displayPreferences.forceWindowBadge,
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
                guard let target = self.windowSnapshot().targets.first(where: { $0.pid == Int(pid) && $0.frame == frame }) else {
                    self.trackMotion([]); self.hide("Window geometry unavailable"); return
                }
                self.focusedMotionIdentity = target.identity
                self.trackMotion([target])
                self.show(zone: zone, window: frame, motionIdentity: target.identity)
            }
        }
    }

    private func clearDebugOverlays() {
        for target in debugOverlays.values { target.panel.close() }
        debugOverlays.removeAll()
        debugOrder.removeAll()
        _ = debugWindows.update([])
        debugProcesses.removeAll(); debugLastQuery = .distantPast
    }

    private func tickDebug() {
        process = nil
        let snapshot = windowSnapshot()
        let visible = snapshot.targets
        focusedMotionIdentity = nil
        trackMotion(visible.filter { debugProcesses[$0.applicationIdentity]?.debugZone(pid: $0.pid, executable: $0.executable,
            launchedAt: $0.launchedAt, system: .autoupdatingCurrent) != nil })
        for removed in debugWindows.update(visible) {
            debugOverlays.removeValue(forKey: removed)?.panel.close()
        }
        panel.orderOut(nil)
        let order = visible.map(\.identity)
        let orderChanged = debugOrder != order
        debugOrder = order
        let applications = Dictionary(visible.map { ($0.applicationIdentity, $0) }, uniquingKeysWith: { first, _ in first })
        debugProcesses = debugProcesses.filter { applications[$0.key] != nil }
        var displayed: Set<String> = []
        for window in visible.reversed() {
            guard let zone = debugProcesses[window.applicationIdentity]?.debugZone(pid: window.pid, executable: window.executable,
                launchedAt: window.launchedAt, system: .autoupdatingCurrent) else { continue }
            let target = debugOverlays[window.identity] ?? WindowBadgeOverlay()
            debugOverlays[window.identity] = target
            guard let context = WindowBadgeOcclusion(windowID: window.windowID, surfaces: snapshot.surfaces) else { continue }
            show(zone: zone, window: window.frame, debug: true, target: target, occluders: context.foreground, neighbors: context.neighbors, motionIdentity: window.identity)
            if target.panel.isVisible { displayed.insert(window.identity) }
            if orderChanged && target.panel.isVisible { target.panel.orderFrontRegardless() }
        }
        for key in Array(debugOverlays.keys) where !displayed.contains(key) {
            debugOverlays.removeValue(forKey: key)?.panel.close()
        }
        status("Debug · \(debugOverlays.count) windows")
        diagnose()
        guard !applications.isEmpty, store.online, !debugInFlight, Date().timeIntervalSince(debugLastQuery) >= 2 else { return }
        debugLastQuery = Date(); debugInFlight = true
        let socket = store.stateDirectory.appendingPathComponent("control.sock").path
        queue.async { [weak self] in
            var observed: [String: WindowBadgeProcess] = [:]
            for (key, window) in applications {
                let response = TZControl(socket, ["command": "process", "pid": window.pid])
                let data = (response?["process"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                if let data, let process = try? JSONDecoder().decode(WindowBadgeProcess.self, from: data) { observed[key] = process }
            }
            Task { @MainActor in
                guard let self else { return }
                self.debugInFlight = false
                guard self.store.displayPreferences.forceWindowBadge else { return }
                let current = Set(self.debugWindows.windows.values.map(\.applicationIdentity))
                self.debugProcesses = observed.filter { current.contains($0.key) }
            }
        }
    }

    private func windowSnapshot() -> (targets: [WindowBadgeWindow], surfaces: [WindowBadgeSurface]) {
        let cached = self.applications ?? {
            let all = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
            return (all, Set(all.filter { $0.value.activationPolicy == .prohibited }.keys))
        }()
        self.applications = cached
        let applications = cached.all
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map(\.frame)
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let badgeIDs = Set(([overlay] + Array(debugOverlays.values)).map { $0.panel.windowNumber })
        // Occlusion uses the complete WindowServer order, independently of badge eligibility.
        let surfaces: [WindowBadgeSurface] = windows.compactMap { value in
            guard let layer = value[kCGWindowLayer as String] as? Int, layer >= 0,
                  let number = value[kCGWindowNumber as String] as? NSNumber, !badgeIDs.contains(number.intValue),
                  (value[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0 else { return nil }
            let frame = CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
            let pid = value[kCGWindowOwnerPID as String] as? Int ?? 0
            // Dock owns a screen-sized desktop surface whose bounds are not opaque coverage.
            guard !WindowBadgeSurface.isDockDesktopSurface(bundleIdentifier: applications[pid_t(pid)]?.bundleIdentifier,
                layer: layer, dockLayer: Int(CGWindowLevelForKey(.dockWindow)), frame: frame, screens: screens) else { return nil }
            return WindowBadgeSurface(windowID: number.uint32Value, frame: frame)
        }
        let targets: [WindowBadgeWindow] = windows.compactMap { value in
            guard value[kCGWindowLayer as String] as? Int == 0,
                  let pid = value[kCGWindowOwnerPID as String] as? Int,
                  let app = applications[pid_t(pid)], !cached.prohibited.contains(pid_t(pid)),
                  app.bundleURL?.pathExtension.lowercased() == "app",
                  let executable = app.executableURL?.resolvingSymlinksInPath().path, let launchDate = app.launchDate,
                  let number = value[kCGWindowNumber as String] as? NSNumber,
                  let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0 else { return nil }
            let frame = CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
            guard screens.contains(where: { $0.intersects(frame) }) else { return nil }
            return WindowBadgeWindow(windowID: number.uint32Value, pid: pid, executable: executable,
                launchedAt: launchDate.timeIntervalSince1970, frame: frame)
        }
        return (targets, surfaces)
    }

    private func show(zone: TimeZone, window: CGRect, preview: Bool = false, debug: Bool = false, target: WindowBadgeOverlay? = nil, occluders: [CGRect] = [], neighbors: [CGRect] = [], motionIdentity: String? = nil) {
        let target = target ?? overlay
        if let motionIdentity, motion.isSuppressed(motionIdentity, at: ProcessInfo.processInfo.systemUptime) {
            target.panel.orderOut(nil); return
        }
        var policy = PolicyDocument(); policy.default_mode = "fixed"; policy.default_zone = zone.identifier
        let city = clock.make(policy: policy, preferences: store.displayPreferences).city
        let title = (preview ? "Preview · " : (debug ? "Debug · " : "")) + city
        let offset = MenuTimeZone.offset(for: zone, at: Date())
        let text = NSMutableAttributedString(string: title + "  ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: offset, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
        let size = CGSize(width: ceil(text.size().width) + 38, height: 24)
        let screens = NSScreen.screens.map(\.visibleFrame)
        let placement = debug ? WindowBadgePlacement.debugFrame(window: window, size: size, screens: screens, occluders: occluders, neighbors: neighbors)
            : WindowBadgePlacement.frame(window: window, size: size, screens: screens, neighbors: windowSnapshot().surfaces.map(\.frame))
        guard let frame = placement else {
            target.panel.orderOut(nil)
            if target === overlay { hide("Hidden — no space outside the window") }
            return
        }
        target.label.attributedStringValue = text
        target.label.setAccessibilityLabel("\(city), UTC\(offset)" + (preview ? ", Preview" : (debug ? ", Debug" : "")))
        target.panel.setFrame(frame, display: true)
        if !target.panel.isVisible { target.panel.orderFrontRegardless() }
        if target === overlay {
            status(preview ? "Preview" : "\(debug ? "Debug · " : "")\(city) \(offset)")
            diagnose(window: window)
        }
    }

    private func hide(_ value: String) { if panel.isVisible { panel.orderOut(nil) }; status(value); diagnose() }
    private func status(_ value: String) { if store.windowBadgeStatus != value { store.windowBadgeStatus = value } }

    private func diagnose(window: CGRect? = nil) {
        guard let diagnostics else { return }
        func rect(_ value: CGRect) -> [String: Double] {
            ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        let debugVisible = debugOverlays.filter { $0.value.panel.isVisible }
        var state: [String: Any] = ["visible": panel.isVisible || !debugVisible.isEmpty, "status": store.windowBadgeStatus,
            "frontmost_pid": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),
            "mouse_passthrough": panel.ignoresMouseEvents, "is_key_window": panel.isKeyWindow,
            "accessibility_trusted": AXIsProcessTrusted()]
        state["moving_windows"] = motionTargets.values.filter {
            motion.isSuppressed($0.identity, at: ProcessInfo.processInfo.systemUptime)
        }.map(\.identity).sorted()
        state["tracked_windows"] = motionTargets.values.map(\.identity).sorted()
        state["screens"] = NSScreen.screens.map { rect($0.visibleFrame) }
        state["debug_badges"] = debugVisible.map { key, target -> [String: Any] in
            ["identity": key, "badge": rect(target.panel.frame), "text": target.label.stringValue,
             "mouse_passthrough": target.panel.ignoresMouseEvents, "is_key_window": target.panel.isKeyWindow]
        }.sorted { ($0["identity"] as? String ?? "") < ($1["identity"] as? String ?? "") }
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

@MainActor
private final class WindowBadgeOverlay {
    let panel = WindowBadgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let label = NSTextField(labelWithString: "")

    init() {
        panel.title = "Yoyo Window Badge"
        panel.isReleasedWhenClosed = false
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
    }
}

private final class WindowBadgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

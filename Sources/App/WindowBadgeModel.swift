import Foundation
import CoreGraphics

struct WindowBadgeMotion {
    private var frames: [String: CGRect] = [:]
    private var resumeAt: [String: Double] = [:]

    mutating func update(_ current: [String: CGRect], at now: Double) {
        resumeAt = resumeAt.filter { current[$0.key] != nil }
        for (identity, frame) in current {
            if let previous = frames[identity], previous != frame { resumeAt[identity] = now + 0.3 }
        }
        frames = current
    }

    func isSuppressed(_ identity: String, at now: Double) -> Bool {
        now < (resumeAt[identity] ?? 0)
    }
}

struct WindowBadgeWindow {
    var windowID: UInt32
    var pid: Int
    var executable: String
    var launchedAt: Double
    var frame: CGRect

    var applicationIdentity: String { "\(pid):\(launchedAt):\(executable)" }
    var identity: String { "\(applicationIdentity):\(windowID)" }
}

struct WindowBadgeSurface {
    var windowID: UInt32
    var frame: CGRect

    static func isDockDesktopSurface(bundleIdentifier: String?, layer: Int, dockLayer: Int, frame: CGRect, screens: [CGRect]) -> Bool {
        guard bundleIdentifier == "com.apple.dock", layer == dockLayer else { return false }
        return screens.contains { screen in
            abs(screen.minX - frame.minX) < 1 && abs(screen.minY - frame.minY) < 1 &&
                abs(screen.width - frame.width) < 1 && abs(screen.height - frame.height) < 1
        }
    }
}

struct WindowBadgeOcclusion {
    var foreground: [CGRect]
    var neighbors: [CGRect]

    init?(windowID: UInt32, surfaces: [WindowBadgeSurface]) {
        guard let index = surfaces.firstIndex(where: { $0.windowID == windowID }) else { return nil }
        foreground = surfaces.prefix(index).map(\.frame)
        neighbors = surfaces.filter { $0.windowID != windowID }.map(\.frame)
    }
}

struct WindowBadgeWindows {
    private(set) var windows: [String: WindowBadgeWindow] = [:]

    mutating func update(_ visible: [WindowBadgeWindow]) -> Set<String> {
        let next = Dictionary(visible.map { ($0.identity, $0) }, uniquingKeysWith: { _, latest in latest })
        let removed = Set(windows.keys).subtracting(next.keys)
        windows = next
        return removed
    }
}

struct WindowBadgeProcess: Codable {
    var pid: Int
    var path: String
    var started_at: Double
    var mode: String
    var zone: String
    var loaded: Bool

    func confirmedZone(pid expectedPID: Int, executable: String, launchedAt: Double) -> TimeZone? {
        guard loaded else { return nil }
        return launchZone(pid: expectedPID, executable: executable, launchedAt: launchedAt)
    }

    func launchZone(pid expectedPID: Int, executable: String, launchedAt: Double) -> TimeZone? {
        guard pid == expectedPID, mode == "fixed", abs(started_at - launchedAt) < 1,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == executable else { return nil }
        return TimeZone(identifier: zone)
    }

    func debugZone(pid expectedPID: Int, executable: String, launchedAt: Double, system: TimeZone) -> TimeZone? {
        guard let zone = launchZone(pid: expectedPID, executable: executable, launchedAt: launchedAt),
              zone.identifier != system.identifier, (zone as NSTimeZone).data != (system as NSTimeZone).data else { return nil }
        return zone
    }
}

enum WindowBadgePlacement {
    static func debugFrame(window: CGRect, size: CGSize, screens: [CGRect], occluders: [CGRect] = [], neighbors: [CGRect] = []) -> CGRect? {
        guard let anchor = frame(window: window, size: size, screens: screens, neighbors: occluders + neighbors) else { return nil }
        // Hide when the edge the badge belongs to is covered, even if its outside space is free.
        let attachment = CGPoint(x: min(max(anchor.midX, window.minX + 1), window.maxX - 1),
            y: min(max(anchor.midY, window.minY + 1), window.maxY - 1))
        guard !occluders.contains(where: { $0.contains(attachment) }) else { return nil }
        return anchor
    }

    static func frame(window: CGRect, size: CGSize, screens: [CGRect], neighbors: [CGRect] = []) -> CGRect? {
        guard window.width > 0, window.height > 0, size.width > 0, size.height > 0,
              let screen = screens.max(by: { area($0.intersection(window)) < area($1.intersection(window)) }),
              area(screen.intersection(window)) > 0 else { return nil }
        // Screen geometry chooses a stable edge; other windows only control visibility.
        guard let anchor = candidates(window: window, size: size).first(where: {
            screen.insetBy(dx: 4, dy: 4).contains($0) && !$0.intersects(window)
        }), !neighbors.contains(where: { $0.intersects(anchor) }) else { return nil }
        return anchor
    }

    private static func candidates(window: CGRect, size: CGSize) -> [CGRect] {
        [
            CGRect(x: window.maxX - size.width - 8, y: window.maxY + 6, width: size.width, height: size.height),
            CGRect(x: window.maxX + 6, y: window.maxY - size.height - 8, width: size.width, height: size.height),
            CGRect(x: window.maxX - size.width - 8, y: window.minY - size.height - 6, width: size.width, height: size.height),
            CGRect(x: window.minX - size.width - 6, y: window.maxY - size.height - 8, width: size.width, height: size.height)
        ]
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}

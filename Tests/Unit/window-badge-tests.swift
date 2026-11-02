import Foundation
import CoreGraphics

@main
struct WindowBadgeTests {
    static func main() {
        var motion = WindowBadgeMotion()
        let original = CGRect(x: 100, y: 100, width: 600, height: 400)
        motion.update(["browser": original, "other": original], at: 1)
        for sample in [1.01, 1.1, 1.3, 2.0] {
            motion.update(["browser": original, "other": original], at: sample)
            assert(!motion.isSuppressed("browser", at: sample), "Scrolling and text/scrollbar dragging with unchanged bounds must not hide badges")
        }
        let translated = original.offsetBy(dx: 20, dy: 10)
        motion.update(["browser": translated, "other": original], at: 3)
        assert(motion.isSuppressed("browser", at: 3))
        assert(!motion.isSuppressed("other", at: 3), "Moving one window must not hide another window's badge")
        motion.update(["browser": translated, "other": original], at: 3.2)
        assert(motion.isSuppressed("browser", at: 3.2))
        assert(!motion.isSuppressed("browser", at: 3.31))
        var resized = translated; resized.size.width += 20
        motion.update(["browser": resized], at: 4)
        assert(motion.isSuppressed("browser", at: 4))
        motion.update([:], at: 4.1)
        motion.update(["browser": original], at: 4.2)
        assert(!motion.isSuppressed("browser", at: 4.2), "Recreated windows must not inherit stale movement state")
        let executable = URL(fileURLWithPath: "/usr/bin/true").resolvingSymlinksInPath().path
        var process = WindowBadgeProcess(pid: 42, path: executable, started_at: 100, mode: "fixed", zone: "Asia/Tokyo", loaded: true)
        func zone(_ value: WindowBadgeProcess) -> TimeZone? { value.confirmedZone(pid: 42, executable: executable, launchedAt: 100) }
        assert(zone(process)?.identifier == "Asia/Tokyo")
        process.loaded = false; assert(zone(process) == nil)
        assert(process.launchZone(pid: 42, executable: executable, launchedAt: 100)?.identifier == "Asia/Tokyo")
        assert(process.debugZone(pid: 42, executable: executable, launchedAt: 100, system: TimeZone(identifier: "Etc/UTC")!)?.identifier == "Asia/Tokyo")
        assert(process.debugZone(pid: 42, executable: executable, launchedAt: 100, system: TimeZone(identifier: "Japan")!) == nil)
        assert(process.launchZone(pid: 43, executable: executable, launchedAt: 100) == nil)
        process.loaded = true; process.pid = 43; assert(zone(process) == nil)
        process.pid = 42; process.started_at = 102; assert(zone(process) == nil)
        process.started_at = 100; process.path = "/usr/bin/false"; assert(zone(process) == nil)
        process.path = executable; process.mode = "default"; assert(zone(process) == nil)
        assert(process.debugZone(pid: 42, executable: executable, launchedAt: 100, system: TimeZone(identifier: "Etc/UTC")!) == nil)
        process.mode = "fixed"; process.zone = "Invalid/Zone"; assert(zone(process) == nil)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 130, height: 24)
        let normal = CGRect(x: 100, y: 100, width: 600, height: 400)
        let anchored = WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen])!
        assert(!anchored.intersects(normal), "Even debug badges must stay outside window content and titlebar controls")
        let above = WindowBadgePlacement.frame(window: normal, size: size, screens: [screen])!
        assert(above.minY == normal.maxY + 6 && !above.intersects(normal))
        let rearWindow = CGRect(x: 300, y: 300, width: 600, height: 400)
        let context = WindowBadgeOcclusion(windowID: 1, surfaces: [WindowBadgeSurface(windowID: 1, frame: normal),
            WindowBadgeSurface(windowID: 2, frame: rearWindow)])!
        assert(context.foreground.isEmpty)
        let debugAbove = WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen], occluders: context.foreground)!
        assert(debugAbove == anchored && !normal.intersects(debugAbove))
        assert(WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen],
            occluders: context.foreground, neighbors: context.neighbors) == nil, "A background neighbor can cover the outside anchor")
        assert(WindowBadgePlacement.frame(window: normal, size: size, screens: [screen], neighbors: [rearWindow]) == nil,
            "An occluded outside anchor must hide instead of jumping to another edge")
        let top = CGRect(x: 100, y: 500, width: 600, height: 400)
        assert(WindowBadgePlacement.frame(window: top, size: size, screens: [screen])!.minX == top.maxX + 6)
        let corner = CGRect(x: 1000, y: 500, width: 440, height: 400)
        assert(WindowBadgePlacement.frame(window: corner, size: size, screens: [screen])!.maxY == corner.minY - 6)
        assert(WindowBadgePlacement.frame(window: screen, size: size, screens: [screen]) == nil)
        assert(WindowBadgePlacement.debugFrame(window: screen, size: size, screens: []) == nil)
        assert(WindowBadgePlacement.debugFrame(window: screen, size: CGSize(width: 2000, height: 24), screens: [screen]) == nil)
        assert(WindowBadgePlacement.debugFrame(window: screen, size: size, screens: [screen]) == nil,
            "A maximized window must hide its badge instead of covering titlebar buttons or content")
        let foreground = CGRect(x: 80, y: 80, width: 660, height: 460)
        let foreignContext = WindowBadgeOcclusion(windowID: 1, surfaces: [WindowBadgeSurface(windowID: 9, frame: foreground),
            WindowBadgeSurface(windowID: 1, frame: normal)])!
        assert(WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen], occluders: foreignContext.foreground) == nil,
            "Occluding surfaces need no application identity or badge eligibility")
        assert(WindowBadgeOcclusion(windowID: 123, surfaces: []) == nil)
        assert(WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen], occluders: [foreground]) == nil,
            "A fully covered background window must not leave a floating badge over the foreground app")
        let coverTop = CGRect(x: 0, y: 300, width: 1440, height: 600)
        assert(WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen], occluders: [coverTop]) == nil,
            "A covered top-right anchor must not relocate into the body of the window")
        let coverAnchor = anchored.insetBy(dx: -5, dy: -5)
        for blockers in [[], [CGRect(x: 100, y: 100, width: 100, height: 100)], [coverAnchor], [], [coverTop], []] {
            let placed = WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen], occluders: blockers)
            assert(placed == nil || placed == anchored, "Occlusion changes may only hide/show the fixed anchor")
        }
        let moved = normal.offsetBy(dx: 20, dy: 30)
        assert(WindowBadgePlacement.debugFrame(window: moved, size: size, screens: [screen]) == anchored.offsetBy(dx: 20, dy: 30))
        let coverBottom = CGRect(x: 0, y: 0, width: 1440, height: 300)
        assert(WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen], occluders: [coverTop, coverBottom]) == nil)
        let surround = [
            CGRect(x: 0, y: 500, width: 1440, height: 400),
            CGRect(x: 0, y: 0, width: 1440, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 900),
            CGRect(x: 700, y: 0, width: 740, height: 900)
        ]
        assert(WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen], occluders: surround) == nil,
            "No outside space must never trigger an inside fallback")
        let leftScreen = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        assert(WindowBadgeSurface.isDockDesktopSurface(bundleIdentifier: "com.apple.dock", layer: 20, dockLayer: 20,
            frame: screen, screens: [screen, leftScreen]))
        assert(WindowBadgeSurface.isDockDesktopSurface(bundleIdentifier: "com.apple.dock", layer: 20, dockLayer: 20,
            frame: leftScreen, screens: [screen, leftScreen]))
        assert(!WindowBadgeSurface.isDockDesktopSurface(bundleIdentifier: "com.apple.dock", layer: 20, dockLayer: 20,
            frame: CGRect(x: 500, y: 0, width: 400, height: 70), screens: [screen]), "The real Dock bar still blocks placement")
        assert(!WindowBadgeSurface.isDockDesktopSurface(bundleIdentifier: "com.example.app", layer: 20, dockLayer: 20,
            frame: screen, screens: [screen]), "Other full-screen windows must remain occluders")
        assert(!WindowBadgeSurface.isDockDesktopSurface(bundleIdentifier: "com.apple.dock", layer: 3, dockLayer: 20,
            frame: screen, screens: [screen]), "Other Dock layers must not be excluded")
        let scene: [(String, Int, WindowBadgeSurface)] = [
            ("com.apple.dock", 20, WindowBadgeSurface(windowID: 55, frame: screen)),
            ("com.example.target", 0, WindowBadgeSurface(windowID: 1, frame: normal))]
        let filtered = scene.filter { !WindowBadgeSurface.isDockDesktopSurface(bundleIdentifier: $0.0, layer: $0.1,
            dockLayer: 20, frame: $0.2.frame, screens: [screen, leftScreen]) }.map { $0.2 }
        let primaryContext = WindowBadgeOcclusion(windowID: 1, surfaces: filtered)!
        assert(WindowBadgePlacement.debugFrame(window: normal, size: size, screens: [screen, leftScreen],
            occluders: primaryContext.foreground) != nil,
            "The primary display must retain its badge when Dock exposes a screen-sized desktop surface")
        let leftWindow = CGRect(x: -1100, y: 100, width: 600, height: 400)
        assert(WindowBadgePlacement.frame(window: leftWindow, size: size, screens: [screen, leftScreen])!.maxX < 0)
        assert(WindowBadgePlacement.frame(window: CGRect(x: 3000, y: 0, width: 400, height: 400), size: size, screens: [screen]) == nil)
        var visible = WindowBadgeWindows()
        var first = WindowBadgeWindow(windowID: 1, pid: 42, executable: executable, launchedAt: 100, frame: normal)
        let second = WindowBadgeWindow(windowID: 2, pid: 42, executable: executable, launchedAt: 100, frame: top)
        let otherApp = WindowBadgeWindow(windowID: 3, pid: 43, executable: executable, launchedAt: 200, frame: leftWindow)
        assert(visible.update([first, second, otherApp]).isEmpty && visible.windows.count == 3)
        // Focus/z-order changes retain all windows, including the background app.
        assert(visible.update([otherApp, second, first]).isEmpty && visible.windows.count == 3)
        first.frame.origin.x += 20
        assert(visible.update([first, second, otherApp]).isEmpty)
        assert(visible.windows[first.identity]?.frame == first.frame)
        // Closed, minimized or other-Space windows disappear from the snapshot.
        assert(visible.update([first]) == Set([second.identity, otherApp.identity]))
        var relaunched = first; relaunched.launchedAt += 1
        assert(relaunched.identity != first.identity)
        assert(visible.update([relaunched]) == Set([first.identity]))
        assert(visible.update([]) == Set([relaunched.identity]) && visible.windows.isEmpty)
        print("Window badge: confirmed hooks, PID/path/start identity, exclusions, edge fallbacks, full screen and multiple displays: PASS")
        print("Debug badges: multiple unfocused windows retained, movement tracked and stale windows removed: PASS")
    }
}

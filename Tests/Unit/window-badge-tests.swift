import Foundation
import CoreGraphics

@main
struct WindowBadgeTests {
    static func main() {
        let executable = URL(fileURLWithPath: "/usr/bin/true").resolvingSymlinksInPath().path
        var process = WindowBadgeProcess(pid: 42, path: executable, started_at: 100, mode: "fixed", zone: "Asia/Tokyo", loaded: true)
        func zone(_ value: WindowBadgeProcess) -> TimeZone? { value.confirmedZone(pid: 42, executable: executable, launchedAt: 100) }
        assert(zone(process)?.identifier == "Asia/Tokyo")
        process.loaded = false; assert(zone(process) == nil)
        process.loaded = true; process.pid = 43; assert(zone(process) == nil)
        process.pid = 42; process.started_at = 102; assert(zone(process) == nil)
        process.started_at = 100; process.path = "/usr/bin/false"; assert(zone(process) == nil)
        process.path = executable; process.mode = "default"; assert(zone(process) == nil)
        process.mode = "fixed"; process.zone = "Invalid/Zone"; assert(zone(process) == nil)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 130, height: 24)
        let normal = CGRect(x: 100, y: 100, width: 600, height: 400)
        let above = WindowBadgePlacement.frame(window: normal, size: size, screens: [screen])!
        assert(above.minY == normal.maxY + 6 && !above.intersects(normal))
        let top = CGRect(x: 100, y: 500, width: 600, height: 400)
        assert(WindowBadgePlacement.frame(window: top, size: size, screens: [screen])!.minX == top.maxX + 6)
        let corner = CGRect(x: 1000, y: 500, width: 440, height: 400)
        assert(WindowBadgePlacement.frame(window: corner, size: size, screens: [screen])!.maxY == corner.minY - 6)
        assert(WindowBadgePlacement.frame(window: screen, size: size, screens: [screen]) == nil)
        let leftScreen = CGRect(x: -1200, y: 0, width: 1200, height: 800)
        let leftWindow = CGRect(x: -1100, y: 100, width: 600, height: 400)
        assert(WindowBadgePlacement.frame(window: leftWindow, size: size, screens: [screen, leftScreen])!.maxX < 0)
        assert(WindowBadgePlacement.frame(window: CGRect(x: 3000, y: 0, width: 400, height: 400), size: size, screens: [screen]) == nil)
        print("Window badge: confirmed hooks, PID/path/start identity, exclusions, edge fallbacks, full screen and multiple displays: PASS")
    }
}

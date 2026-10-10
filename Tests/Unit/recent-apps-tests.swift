import Foundation

@main
struct RecentAppsTests {
    static func candidate(_ id: String, path: String? = nil, pid: Int = 10, opened: Double = 10,
                          policy: Int = 0, background: Bool = false, main: Bool = true) -> AppLaunchCandidate {
        let bundle = path ?? "/Applications/\(id).app"
        return AppLaunchCandidate(app: RecentApp(id: id, path: bundle, executable: bundle + "/Contents/MacOS/Main",
                                                name: id, pid: pid, opened_at: opened),
                                  activationPolicy: policy, backgroundOnly: background, isMainExecutable: main)
    }
    static func main() throws {
        var history = RecentAppCollection()
        assert(history.record(candidate("ordinary"), excluding: "dev.timezone.lab"))
        assert(history.record(candidate("menubar", opened: 20, policy: 1), excluding: "dev.timezone.lab"))
        assert(!history.record(candidate("background", policy: 2), excluding: "dev.timezone.lab"))
        assert(!history.record(candidate("agent", background: true), excluding: "dev.timezone.lab"))
        assert(!history.record(candidate("cli", path: "/usr/bin/head"), excluding: "dev.timezone.lab"))
        assert(!history.record(candidate("helper", path: "/Applications/ordinary.app/Contents/Helpers/Worker.app"), excluding: "dev.timezone.lab"))
        assert(!history.record(candidate("ordinary", opened: 30, main: false), excluding: "dev.timezone.lab"))
        assert(!history.record(candidate("system", path: "/System/Library/CoreServices/Agent.app"), excluding: "dev.timezone.lab"))
        assert(!history.record(candidate("dev.timezone.lab"), excluding: "dev.timezone.lab"))
        let before = history.apps
        for _ in 0..<1000 { assert(!history.record(candidate("ordinary"), excluding: "dev.timezone.lab")) }
        assert(history.apps == before) // Focus, duplicate notifications and helper work cannot bump an app.
        assert(history.record(candidate("ordinary", pid: 11, opened: 40), excluding: "dev.timezone.lab"))
        assert(history.apps.count == 2 && history.apps[0].id == "ordinary" && history.apps[0].opened_at == 40)
        let data = try JSONEncoder().encode(history.apps)
        var restored = RecentAppCollection(); try restored.restore(data)
        assert(restored.apps == history.apps)
        for i in 0..<110 { restored.record(candidate("app-\(i)", opened: Double(100 + i)), excluding: "dev.timezone.lab") }
        assert(restored.apps.count == 100 && restored.apps[0].id == "app-109")
        restored.clear(); assert(restored.apps.isEmpty)
        print("Recent apps: GUI/menu bar launches, helper/CLI/background exclusion, stable focus/order, real relaunch, persistence and bounds: PASS")
    }
}

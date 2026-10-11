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
        assert(history.record(candidate("ordinary"), excluding: "yoyo.hola.ac"))
        assert(history.record(candidate("menubar", opened: 20, policy: 1), excluding: "yoyo.hola.ac"))
        assert(!history.record(candidate("background", policy: 2), excluding: "yoyo.hola.ac"))
        assert(!history.record(candidate("agent", background: true), excluding: "yoyo.hola.ac"))
        assert(!history.record(candidate("cli", path: "/usr/bin/head"), excluding: "yoyo.hola.ac"))
        assert(!history.record(candidate("helper", path: "/Applications/ordinary.app/Contents/Helpers/Worker.app"), excluding: "yoyo.hola.ac"))
        assert(!history.record(candidate("ordinary", opened: 30, main: false), excluding: "yoyo.hola.ac"))
        assert(!history.record(candidate("system", path: "/System/Library/CoreServices/Agent.app"), excluding: "yoyo.hola.ac"))
        assert(!history.record(candidate("yoyo.hola.ac"), excluding: "yoyo.hola.ac"))
        let before = history.apps
        for _ in 0..<1000 { assert(!history.record(candidate("ordinary"), excluding: "yoyo.hola.ac")) }
        assert(history.apps == before) // Focus, duplicate notifications and helper work cannot bump an app.
        assert(history.record(candidate("ordinary", pid: 11, opened: 40), excluding: "yoyo.hola.ac"))
        assert(history.apps.count == 2 && history.apps[0].id == "ordinary" && history.apps[0].opened_at == 40)
        let data = try JSONEncoder().encode(history.apps)
        var restored = RecentAppCollection(); try restored.restore(data)
        assert(restored.apps == history.apps)
        for i in 0..<110 { restored.record(candidate("app-\(i)", opened: Double(100 + i)), excluding: "yoyo.hola.ac") }
        assert(restored.apps.count == 100 && restored.apps[0].id == "app-109")
        restored.clear(); assert(restored.apps.isEmpty)
        print("Recent apps: GUI/menu bar launches, helper/CLI/background exclusion, stable focus/order, real relaunch, persistence and bounds: PASS")
    }
}

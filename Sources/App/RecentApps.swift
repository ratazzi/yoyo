import Foundation

struct RecentApp: Codable, Identifiable, Equatable {
    var id: String // Bundle identifier
    var path: String
    var executable: String
    var name: String
    var pid: Int
    var opened_at: Double
}

struct AppLaunchCandidate {
    var app: RecentApp
    var activationPolicy: Int // AppKit: regular = 0, accessory = 1, prohibited = 2
    var backgroundOnly: Bool
    var isMainExecutable: Bool

    func isEligible(excluding bundleID: String) -> Bool {
        let url = URL(fileURLWithPath: app.path)
        return !app.id.isEmpty && app.id != bundleID && app.pid > 0 && app.opened_at > 0 &&
            [0, 1].contains(activationPolicy) && !backgroundOnly && isMainExecutable &&
            url.pathExtension.lowercased() == "app" && app.path.hasPrefix("/") &&
            url.pathComponents.filter { ($0 as NSString).pathExtension.lowercased() == "app" }.count == 1 &&
            !app.path.hasPrefix("/System/Library/") && !app.path.hasPrefix("/Library/Apple/")
    }
}

struct RecentAppCollection {
    private(set) var apps: [RecentApp] = []

    @discardableResult
    mutating func record(_ candidate: AppLaunchCandidate, excluding bundleID: String) -> Bool {
        guard candidate.isEligible(excluding: bundleID) else { return false }
        let app = candidate.app
        if let previous = apps.first(where: { $0.id == app.id }) {
            // Focus changes and duplicate launch notifications do not change recency.
            guard app.opened_at > previous.opened_at else { return false }
        }
        apps.removeAll { $0.id == app.id }
        apps.append(app)
        apps.sort { $0.opened_at > $1.opened_at }
        if apps.count > 100 { apps.removeLast(apps.count - 100) }
        return true
    }

    mutating func restore(_ data: Data) throws {
        let saved = try JSONDecoder().decode([RecentApp].self, from: data)
        for app in saved {
            // This file is produced only by the application lifecycle monitor.
            let candidate = AppLaunchCandidate(app: app, activationPolicy: 0, backgroundOnly: false, isMainExecutable: true)
            record(candidate, excluding: "yoyo.hola.ac")
        }
    }

    mutating func clear() { apps.removeAll() }
}

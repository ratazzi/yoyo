import AppKit

@MainActor
final class AppLaunchMonitor {
    private var history = RecentAppCollection()
    private var observers: [NSObjectProtocol] = []
    private var seenLifetimes = Set<String>()
    private let file: URL
    private let onChange: ([RecentApp]) -> Void
    private let onError: (String) -> Void
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "yoyo.hola.ac"

    init(file: URL, onChange: @escaping ([RecentApp]) -> Void, onError: @escaping (String) -> Void) {
        self.file = file; self.onChange = onChange; self.onError = onError
        if FileManager.default.fileExists(atPath: file.path) {
            do { try history.restore(Data(contentsOf: file)) }
            catch { onError("Could not read recent app history: \(error.localizedDescription)") }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                // The workspace observer is delivered on the main queue.
                MainActor.assumeIsolated { self?.observe(app) }
            })
        }
        // Seed apps already running using their actual launch dates, not "now".
        for app in NSWorkspace.shared.runningApplications { observe(app, save: false) }
        persist()
        onChange(history.apps)
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func observe(_ app: NSRunningApplication, save: Bool = true) {
        guard let bundleID = app.bundleIdentifier, let bundleURL = app.bundleURL,
              let executable = app.executableURL, let launchDate = app.launchDate else { return }
        let path = bundleURL.resolvingSymlinksInPath().path
        let bundle = Bundle(url: bundleURL)
        let candidate = AppLaunchCandidate(
            app: RecentApp(id: bundleID, path: path, executable: executable.resolvingSymlinksInPath().path,
                           name: app.localizedName ?? bundleURL.deletingPathExtension().lastPathComponent,
                           pid: Int(app.processIdentifier), opened_at: launchDate.timeIntervalSince1970),
            activationPolicy: app.activationPolicy.rawValue,
            backgroundOnly: (bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? NSNumber)?.boolValue ?? false,
            isMainExecutable: bundle?.executableURL?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath())
        guard candidate.isEligible(excluding: ownBundleID) else { return }
        let lifetime = "\(bundleID):\(app.processIdentifier):\(launchDate.timeIntervalSince1970)"
        guard seenLifetimes.insert(lifetime).inserted else { return }
        if seenLifetimes.count > 4096 { seenLifetimes = Set(NSWorkspace.shared.runningApplications.compactMap { running in
            guard let id = running.bundleIdentifier, let date = running.launchDate else { return nil }
            return "\(id):\(running.processIdentifier):\(date.timeIntervalSince1970)"
        }) }
        if history.record(candidate, excluding: ownBundleID) {
            if save { persist() }
            onChange(history.apps)
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(history.apps)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { onError("Could not save recent app history: \(error.localizedDescription)") }
    }

    func clear() {
        // Keep known process lifetimes: activating a running app must not refill a cleared list.
        history.clear(); persist(); onChange(history.apps)
    }
}

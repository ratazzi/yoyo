import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppStore: ObservableObject {
    @Published var policy = PolicyDocument()
    @Published var prompts: [LaunchPrompt] = []
    @Published var recentApps: [RecentApp] = []
    @Published var status = "Offline"
    @Published var errorMessage: String?
    @Published var showingSettings = false
    let stateDirectory: URL
    private var polling = false
    private var timer: Timer?
    private var launchMonitor: AppLaunchMonitor?

    var service: SMAppService { .daemon(plistName: "dev.timezone.lab.daemon.plist") }
    var online: Bool { status == "Active" }
    var defaultDescription: String {
        policy.default_mode == "fixed" ? policy.default_zone.replacingOccurrences(of: "_", with: " ") : "System Default"
    }

    init() {
        let configURL = Bundle.main.resourceURL!.appendingPathComponent("lab-config.json")
        let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        stateDirectory = URL(fileURLWithPath: config?["state_directory"] as? String ?? NSTemporaryDirectory() + "TimezoneLab")
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        do {
            let data = try Data(contentsOf: stateDirectory.appendingPathComponent("policy.json"))
            if let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let normalized = TZNormalizePolicy(value) {
                policy = try JSONDecoder().decode(PolicyDocument.self, from: JSONSerialization.data(withJSONObject: normalized))
            } else { errorMessage = "The saved rules could not be read." }
        } catch where (error as NSError).code == NSFileReadNoSuchFileError {
            // First launch starts with no rules and no background service.
        } catch { errorMessage = error.localizedDescription }
        launchMonitor = AppLaunchMonitor(file: stateDirectory.appendingPathComponent("recent-apps.json"), onChange: { [weak self] apps in
            self?.recentApps = apps
        }, onError: { [weak self] error in self?.errorMessage = error })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    @discardableResult
    func save(_ candidate: PolicyDocument) -> Bool {
        do {
            let encoded = try JSONEncoder().encode(candidate)
            let value = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            if let error = TZPolicyError(value) { errorMessage = error; return false }
            guard let normalized = TZNormalizePolicy(value) else { return false }
            let data = try JSONSerialization.data(withJSONObject: normalized, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: stateDirectory.appendingPathComponent("policy.json"), options: .atomic)
            policy = try JSONDecoder().decode(PolicyDocument.self, from: data)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func saveRule(_ rule: ProgramRule) -> Bool {
        var updated = policy
        if let index = updated.rules.firstIndex(where: { $0.id == rule.id }) { updated.rules[index] = rule }
        else { updated.rules.append(rule) }
        return save(updated)
    }

    func removeRule(_ rule: ProgramRule) {
        var updated = policy; updated.rules.removeAll { $0.id == rule.id }; save(updated)
    }

    func setServiceEnabled(_ enabled: Bool) {
        var updated = policy; updated.es_enabled = enabled
        guard save(updated) else { return }
        if enabled {
            do { try service.register() }
            catch { errorMessage = error.localizedDescription }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            service.unregister { [weak self] error in
                Task { @MainActor in if let error { self?.errorMessage = error.localizedDescription } }
            }
        }
    }

    func answer(_ prompt: LaunchPrompt, mode: String, zone: String) {
        guard prompts.contains(where: { $0.id == prompt.id }) else { return }
        if mode == "fixed" && TimeZone(identifier: zone) == nil { errorMessage = "Choose a valid IANA time zone."; return }
        prompts.removeAll { $0.id == prompt.id }
        let path = stateDirectory.appendingPathComponent("control.sock").path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let response = TZControl(path, ["command": "answer", "id": prompt.id, "mode": mode, "zone": zone])
            Task { @MainActor in
                if let error = response?["error"] as? String { self?.errorMessage = error }
                else if response == nil { self?.errorMessage = "The background service did not receive your choice. The launch will be cancelled when the request expires." }
            }
        }
    }

    func poll() {
        guard !polling else { return }; polling = true
        let directory = stateDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reply = TZControl(directory.appendingPathComponent("control.sock").path, ["command": "poll", "include_events": false, "include_processes": false])
            let stateData = try? Data(contentsOf: directory.appendingPathComponent("daemon-state.json"))
            let diskState = stateData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let promptData = reply?["prompts"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            let prompts = promptData.flatMap { try? JSONDecoder().decode([LaunchPrompt].self, from: $0) } ?? []
            Task { @MainActor in
                guard let self else { return }; self.polling = false
                let state = reply?["state"] as? [String: Any] ?? diskState
                let fresh = Date().timeIntervalSince1970 - (state?["updated_at"] as? Double ?? 0) < 8
                let connected = reply != nil && reply?["error"] == nil
                self.status = fresh && state?["status"] as? String == "listening" && connected ? "Active" : "Offline"
                self.prompts = prompts.filter { $0.expires_at > Date().timeIntervalSince1970 }.sorted { $0.expires_at < $1.expires_at }
            }
        }
    }

    func clearHistory() {
        launchMonitor?.clear()
    }
}

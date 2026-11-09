import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private let store: AppStore
    private let defaults = UserDefaults.standard
    private static let restoreServiceKey = "RestoreServiceAfterUpdate"
    private var controller: SPUStandardUpdaterController!
    private var installing = false
    private var serviceRecoveryTask: Task<Void, Never>?
    @Published private(set) var canCheckForUpdates = false
    @Published var channel: UpdateChannel {
        didSet {
            defaults.set(channel.rawValue, forKey: "UpdateChannel")
            controller?.updater.resetUpdateCycleAfterShortDelay()
        }
    }
    @Published var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    init(store: AppStore) {
        self.store = store
        channel = UpdateChannel.selected(saved: UserDefaults.standard.string(forKey: "UpdateChannel"),
            bundled: Bundle.main.object(forInfoDictionaryKey: "YoyoUpdateChannel") as? String)
        super.init()
        restoreServiceIfNeeded()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        // Development builds have no release key and never query production feeds.
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else { return }
        controller.startUpdater()
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    @objc func checkForUpdates(_ sender: Any?) { controller.checkForUpdates(sender) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }
    func feedURLString(for updater: SPUUpdater) -> String? { channel.feedURL }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { installing = true }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installing = false
        restoreServiceIfNeeded()
    }

    // Sparkle also installs on quit. Intercept termination rather than only relaunch.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard installing, store.service.status == .enabled || store.service.status == .requiresApproval else { return .terminateNow }
        defaults.set(true, forKey: Self.restoreServiceKey)
        store.service.unregister { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.store.errorMessage = "Could not stop the background service for the update: \(error.localizedDescription)"
                    self.defaults.removeObject(forKey: Self.restoreServiceKey)
                    NSApp.reply(toApplicationShouldTerminate: false)
                } else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }

    private func restoreServiceIfNeeded() {
        guard defaults.bool(forKey: Self.restoreServiceKey), serviceRecoveryTask == nil else { return }
        serviceRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.serviceRecoveryTask = nil }
            do {
                try await UpdateServiceRecovery.restore(shouldRestore: {
                    self.defaults.bool(forKey: Self.restoreServiceKey) && self.store.policy.es_enabled
                }, register: { try self.store.service.register() })
                self.defaults.removeObject(forKey: Self.restoreServiceKey)
            } catch is CancellationError {
                // Keep the recovery marker for the next launch.
            } catch {
                self.store.errorMessage = "Could not restore the background service after updating: \(error.localizedDescription)"
            }
        }
    }
}

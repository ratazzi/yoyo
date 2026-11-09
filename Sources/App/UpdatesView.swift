import SwiftUI

struct UpdatesView: View {
    @ObservedObject var updater: AppUpdater
    @Binding var channel: UpdateChannel
    @Binding var automaticallyChecks: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Installed version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")")
                .fontWeight(.medium)
            Picker("Update channel", selection: $channel) {
                ForEach(UpdateChannel.allCases) { channel in Text(channel.title).tag(channel) }
            }.disabled(!updater.canCheckForUpdates)
            Text(channel == .nightly
                ? "Daily builds with the latest changes. May be less stable."
                : "Stable releases only. Switching from Nightly waits for a newer stable version.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Automatically check for updates", isOn: $automaticallyChecks).toggleStyle(.checkbox)
                .disabled(!updater.canCheckForUpdates)
            Text("You’ll be asked before an update is installed.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

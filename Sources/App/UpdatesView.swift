import SwiftUI

struct UpdatesView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Software Updates").font(.headline)
            Picker("Update channel", selection: $updater.channel) {
                ForEach(UpdateChannel.allCases) { channel in Text(channel.title).tag(channel) }
            }.disabled(!updater.canCheckForUpdates)
            Text("Nightly builds include the latest changes and may be less stable. Switching to Stable waits for a newer stable build; it does not downgrade this installation.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                .disabled(!updater.canCheckForUpdates)
            Button("Check for Updates…") { updater.checkForUpdates(nil) }.disabled(!updater.canCheckForUpdates)
            Text("Updates are downloaded from GitHub and installed after confirmation. The background service pauses during installation and resumes when Yoyo reopens.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 420)
    }
}

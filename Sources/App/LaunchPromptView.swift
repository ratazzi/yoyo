import SwiftUI

struct LaunchPromptView: View {
    @ObservedObject var store: AppStore
    let prompt: LaunchPrompt
    @State private var zone: String
    private var processChain: String {
        guard let parent = prompt.parent_path, !parent.isEmpty else { return prompt.name }
        return "\((parent as NSString).lastPathComponent) → \(prompt.name)"
    }
    init(store: AppStore, prompt: LaunchPrompt) {
        self.store = store; self.prompt = prompt; _zone = State(initialValue: prompt.zone)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 22) {
                ProgramIcon(path: prompt.path, size: 64)
                    .padding(12).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Choose a time zone for \(prompt.name)").font(.system(size: 23, weight: .semibold))
                    Text("This choice applies to this launch and its child processes.").foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label("\(max(0, Int(prompt.expires_at - context.date.timeIntervalSince1970))) seconds remaining", systemImage: "clock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Surface {
                HStack(spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                    Text(processChain).fontWeight(.semibold)
                        Text(prompt.path).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                }.padding(18)
            }
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Time Zone").fontWeight(.semibold)
                        Spacer()
                        TimeZoneField(selection: $zone).frame(width: 320, height: 26)
                    }
                    Text("Cancel or let this request expire to stop the launch.").font(.callout).foregroundStyle(.secondary)
                }.padding(18)
            }
            Spacer(minLength: 8)
            Divider()
            HStack {
                Button("Cancel Launch") { store.answer(prompt, mode: "cancel", zone: "") }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("System Default") { store.answer(prompt, mode: "default", zone: "") }
                Button("Launch with Time Zone") { store.answer(prompt, mode: "fixed", zone: zone) }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 640)
    }
}

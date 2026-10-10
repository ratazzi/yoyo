import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: AppStore
    @State private var search = ""
    @State private var editingRule: ProgramRule?
    @FocusState private var searchFocused: Bool

    private var filtered: [ProgramRule] {
        store.policy.rules.filter { search.isEmpty || ($0.title + $0.pattern + $0.zone).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search programs", text: $search).textFieldStyle(.plain).focused($searchFocused)
                    Text("⌘F").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(9).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                Menu {
                    Button("Add Application…") { chooseProgram(app: true) }
                    Button("Add Command Line Program…") { chooseProgram(app: false) }
                    Button("Add Path Pattern…") { editingRule = ProgramRule() }
                } label: { Image(systemName: "plus").font(.title3) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Add a program rule")
                Divider().frame(height: 24)
                Button { store.showingSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Settings")
            }
            .padding(.leading, 90).padding(.trailing, 20).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !store.online {
                        Surface {
                            HStack(spacing: 14) {
                                Image(systemName: "pause.circle").font(.title2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.policy.es_enabled ? "Background Service Needs Attention" : "Background Service Is Off").fontWeight(.medium)
                                    Text(store.policy.es_enabled ? "Check permissions or restart the background service." : "Enable it to apply time zones whenever a program starts.").font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Set Up…") { store.showingSettings = true }
                            }.padding(14)
                        }
                    }
                    section(title: "APPLICATIONS", kind: "app")
                    section(title: "COMMAND LINE", kind: "cli")
                    if filtered.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "globe").font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                            Text(search.isEmpty ? "No Program Rules" : "No Matching Programs").font(.title3).fontWeight(.medium)
                            Text(search.isEmpty ? "Add a program to give it a fixed time zone, ask each launch, or use the system default." : "Try another name, path, or time zone.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
                            if search.isEmpty { Button("Add Application…") { chooseProgram(app: true) } }
                        }.frame(maxWidth: .infinity).padding(.vertical, 46)
                    }
                    Surface {
                        HStack(spacing: 12) {
                            Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(Color.accentColor)
                                .frame(width: 30, height: 30).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Default Time Zone").font(.system(size: 13, weight: .medium))
                                Text("For programs without a rule").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(store.defaultDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("Change…") { store.showingSettings = true }
                        }.padding(12)
                    }
                    Text("Child processes inherit the launch choice unless they have their own rule.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6)
                }.padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingRule) { rule in RuleEditor(store: store, initial: rule) }
        .sheet(isPresented: $store.showingSettings) { SettingsView(store: store) }
        .alert("Timezone Lab", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .init("FocusProgramSearch"))) { _ in searchFocused = true }
    }

    @ViewBuilder
    private func section(title: String, kind: String) -> some View {
        let rules = filtered.filter { $0.kind == kind }
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(title); Spacer(); Text("\(rules.count)") }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
                Surface {
                    VStack(spacing: 0) {
                        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                            Button { editingRule = rule } label: {
                                HStack(spacing: 12) {
                                    ProgramIcon(path: rule.pattern, size: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(rule.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                                        Text(rule.pattern).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 16)
                                    if rule.logging { Image(systemName: "doc.text").foregroundStyle(.tertiary).help("Behavior is recorded to a log file") }
                                    Text(rule.enabled ? rule.summary : "Disabled").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                                }.padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if index != rules.count - 1 { Divider().padding(.leading, 54) }
                        }
                    }
                }
            }
        }
    }

    private func chooseProgram(app: Bool) {
        let panel = NSOpenPanel()
        panel.title = app ? "Choose an Application" : "Choose a Command Line Program"
        panel.canChooseDirectories = app; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = !app
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            if app && url.pathExtension.lowercased() != "app" { store.errorMessage = "Choose an .app application bundle."; return }
            if !app && !FileManager.default.isExecutableFile(atPath: url.path) { store.errorMessage = "Choose an executable file."; return }
            var rule = ProgramRule(); rule.kind = app ? "app" : "cli"
            rule.pattern = url.resolvingSymlinksInPath().path; rule.name = url.deletingPathExtension().lastPathComponent
            editingRule = rule
        }
    }
}

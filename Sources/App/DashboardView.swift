import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: AppStore
    @State private var search = ""
    @State private var editingRule: ProgramRule?
    @State private var isDropTargeted = false
    @State private var pendingImports: [ProgramRule] = []
    @State private var importWarning: String?
    @State private var showingAllRecent = false
    @FocusState private var searchFocused: Bool

    private var filtered: [ProgramRule] {
        store.policy.rules.filter { search.isEmpty || ($0.title + $0.pattern + $0.zone).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
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
            }
            .padding(.horizontal, 12).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                    recentSection
                    if filtered.isEmpty && (search.isEmpty || matchingRecent.isEmpty) {
                        VStack(spacing: 14) {
                            Image(systemName: "globe").font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                            Text(search.isEmpty ? "No Program Rules" : "No Matching Programs").font(.title3).fontWeight(.medium)
                            Text(search.isEmpty ? "Drop applications or executables here to add time zone rules." : "Try another name, path, or time zone.")
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
                            Text(store.defaultDescription).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Change…") { store.showingSettings = true }
                        }.padding(12)
                    }
                    Text("Child processes inherit the launch choice unless they have their own rule.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6)
                }.padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "plus.app").font(.system(size: 36, weight: .light)).foregroundStyle(Color.accentColor)
                            Text("Drop Applications or Executables").font(.title3).fontWeight(.semibold)
                            Text("Review a time zone rule for each program.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(12).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importPrograms(urls)
        } isTargeted: { isDropTargeted = $0 }
        .sheet(item: $editingRule, onDismiss: advanceImport) { rule in RuleEditor(store: store, initial: rule) }
        .sheet(isPresented: $store.showingSettings) { SettingsView(store: store) }
        .alert("Timezone Lab", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .init("FocusProgramSearch"))) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .init("EditProgramRule"))) { notification in
            guard !store.showingSettings, editingRule == nil,
                  let id = notification.object as? String else { return }
            editingRule = store.policy.rules.first { $0.id == id }
        }
    }

    private var matchingRecent: [RecentApp] {
        store.recentApps.filter { search.isEmpty || ($0.name + $0.path).localizedCaseInsensitiveContains(search) }
    }

    private func existingRule(for launch: RecentApp) -> ProgramRule? {
        store.policy.rules.first { $0.kind == "app" && $0.pattern == launch.path }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !matchingRecent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("RECENTLY OPENED APPS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if matchingRecent.count > 5 {
                        Button(showingAllRecent ? "Show Less" : "View All") { showingAllRecent.toggle() }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11))
                    }
                    Menu {
                        Button("Clear Recent Apps") { store.clearHistory() }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Recent app history")
                }.padding(.horizontal, 10)
                Surface {
                    VStack(spacing: 0) {
                        let visible = Array(matchingRecent.prefix(showingAllRecent ? 100 : 5))
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, launch in
                            HStack(spacing: 10) {
                                ProgramIcon(path: launch.path, size: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(launch.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(launch.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button(existingRule(for: launch) == nil ? "Add Rule…" : "Edit Rule…") {
                                    if let existing = existingRule(for: launch) { editingRule = existing }
                                    else {
                                        var rule = ProgramRule(); rule.kind = "app"; rule.name = launch.name; rule.pattern = launch.path
                                        editingRule = rule
                                    }
                                }.controlSize(.small)
                            }.padding(.horizontal, 10).padding(.vertical, 8)
                                .help("\(launch.path) · Opened \(Date(timeIntervalSince1970: launch.opened_at).formatted())")
                            if index != visible.count - 1 { Divider().padding(.leading, 46) }
                        }
                    }
                }
            }
        }
    }

    private func importPrograms(_ urls: [URL]) -> Bool {
        guard editingRule == nil, !store.showingSettings else { return false }
        var seen = Set<String>()
        var candidates: [ProgramRule] = []
        var rejected = 0
        for url in urls {
            guard url.isFileURL else { rejected += 1; continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(resolved.path).inserted else { continue }
            let isApp = resolved.pathExtension.lowercased() == "app"
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let valid = isApp
                ? values?.isDirectory == true && Bundle(url: resolved)?.executableURL != nil
                : values?.isRegularFile == true && FileManager.default.isExecutableFile(atPath: resolved.path)
            guard valid else { rejected += 1; continue }
            if let existing = store.policy.rules.first(where: {
                !$0.pattern.contains("*") && URL(fileURLWithPath: $0.pattern).resolvingSymlinksInPath().standardizedFileURL.path == resolved.path
            }) {
                candidates.append(existing)
            } else {
                var rule = ProgramRule()
                rule.kind = isApp ? "app" : "cli"; rule.pattern = resolved.path
                rule.name = isApp ? resolved.deletingPathExtension().lastPathComponent : resolved.lastPathComponent
                candidates.append(rule)
            }
        }
        guard !candidates.isEmpty else {
            if rejected > 0 { store.errorMessage = "Drop .app application bundles or executable files. Other files and folders cannot be added." }
            return false
        }
        search = ""
        importWarning = rejected > 0 ? "Some items were skipped. Only .app application bundles and executable files can be added." : nil
        pendingImports = Array(candidates.dropFirst())
        editingRule = candidates[0]
        return true
    }

    private func advanceImport() {
        if !pendingImports.isEmpty {
            // Present the next sheet after the previous dismissal finishes.
            let next = pendingImports.removeFirst()
            DispatchQueue.main.async { editingRule = next }
        } else if let warning = importWarning {
            importWarning = nil
            DispatchQueue.main.async { store.errorMessage = warning }
        }
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
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if rule.logging { Image(systemName: "doc.text").foregroundStyle(.tertiary).help("Behavior is recorded to a log file") }
                                    Text(rule.enabled ? rule.summary : "Disabled").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                                }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
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

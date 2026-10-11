import SwiftUI
import AppKit
import ServiceManagement

struct RuleEditor: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: ProgramRule
    @State private var validation: String?
    private let existing: Bool

    init(store: AppStore, initial: ProgramRule) {
        self.store = store; _rule = State(initialValue: initial)
        existing = store.policy.rules.contains { $0.id == initial.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                ProgramIcon(path: rule.pattern, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(existing ? "Edit Program Rule" : "Add Program Rule").font(.title2).fontWeight(.semibold)
                    Text("Choose how this program uses time zones.").foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Name", text: $rule.name)
                Picker("Program Type", selection: $rule.kind) {
                    Text("Application").tag("app"); Text("Command Line").tag("cli")
                }
                TextField(rule.kind == "app" ? "Application Path" : "Executable or Pattern", text: $rule.pattern)
                Picker("Time Zone", selection: $rule.mode) {
                    Text("System Default — No Injection").tag("default")
                    Text("Fixed Time Zone").tag("fixed")
                    Text("Ask Every Launch").tag("ask")
                }
                if rule.mode != "default" {
                    LabeledContent(rule.mode == "ask" ? "Suggested Time Zone" : "Fixed Time Zone") {
                        TimeZoneField(selection: $rule.zone).frame(width: 285, height: 26)
                    }
                }
                Toggle("Enable this rule", isOn: $rule.enabled)
                Toggle("Record behavior to a log file", isOn: $rule.logging)
            }.formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            Text(rule.kind == "app" ? "Includes programs inside the application bundle. Explicit child rules take priority." : "Use an absolute path. * matches within one path component. Child processes inherit this launch choice.")
                .font(.callout).foregroundStyle(.secondary)
            if rule.logging {
                Text("Records process activity, file access, and time zone calls. File contents are never recorded.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let validation { Text(validation).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack {
                if existing { Button("Delete Rule", role: .destructive) { store.removeRule(rule); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing ? "Save Changes" : "Add Rule") {
                    if store.saveRule(rule) { dismiss() }
                    else { validation = store.errorMessage; store.errorMessage = nil }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 570)
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var defaultMode = "system"
    @State private var zone = "Asia/Tokyo"
    @State private var validation: String?
    @State private var display = DisplayPreferences()
    @State private var favoriteZone = "Asia/Tokyo"
    @State private var clockFactory = ClockPresentationFactory()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings").font(.title2).fontWeight(.semibold)
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Default Time Zone").fontWeight(.semibold)
                    Picker("Use", selection: $defaultMode) {
                        Text("System Default").tag("system"); Text("Custom Time Zone").tag("fixed")
                    }
                    if defaultMode == "fixed" { TimeZoneField(selection: $zone).frame(height: 26) }
                    Text("Applies to every new program without a matching rule. A System Default rule excludes a program from injection.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(18)
            }
            Surface {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Favorite Time Zones").fontWeight(.semibold)
                    ForEach(display.favoriteTimeZones, id: \.self) { identifier in
                        HStack {
                            Text(identifier.replacingOccurrences(of: "_", with: " "))
                            Spacer()
                            Button { display.favoriteTimeZones.removeAll { $0 == identifier } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.plain).help("Remove favorite")
                        }
                    }
                    HStack {
                        TimeZoneField(selection: $favoriteZone).frame(height: 26)
                        Button("Add") {
                            if TimeZone(identifier: favoriteZone) != nil && !display.favoriteTimeZones.contains(favoriteZone) {
                                display.favoriteTimeZones.append(favoriteZone)
                            }
                        }.disabled(TimeZone(identifier: favoriteZone) == nil || display.favoriteTimeZones.contains(favoriteZone))
                    }
                    Text("Choose a favorite from the menu bar to change the default for new launches.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(18)
            }
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Menu Bar & Dock").fontWeight(.semibold)
                    Picker("Menu Bar", selection: $display.menuBarContent) {
                        ForEach(ClockContent.allCases) { content in Text(content.title).tag(content) }
                    }
                    Toggle("Show Dock Icon", isOn: $display.showDockIcon).toggleStyle(.switch)
                    if display.showDockIcon {
                        Picker("Dock Content", selection: $display.dockContent) {
                            ForEach(ClockContent.allCases) { content in Text(content.title).tag(content) }
                        }
                    }
                    HStack(spacing: 22) {
                        Toggle("24-Hour Time", isOn: $display.use24HourTime)
                        Toggle("Show Seconds", isOn: $display.showSeconds)
                    }.toggleStyle(.checkbox)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let preview = clockFactory.make(policy: previewPolicy, preferences: display, date: context.date)
                        HStack {
                            Text("Menu Bar Preview").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if let label = preview.label(for: display.menuBarContent) {
                                Text(label).monospacedDigit().lineLimit(1)
                            } else { Image(systemName: "globe").foregroundStyle(.secondary) }
                        }
                    }
                    Text("Time and city are hidden when the default matches the system time zone. The app icon stays available.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(18)
            }
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Background Service").fontWeight(.semibold)
                            Text(store.online ? "Active · Applies rules from any launch source" : "Off · Rules are saved for later")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Enable Background Service", isOn: Binding(get: { store.policy.es_enabled }, set: { store.setServiceEnabled($0) })).toggleStyle(.switch).labelsHidden()
                    }
                    HStack {
                        Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        Button("Full Disk Access…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                    }
                    Text("Endpoint Security is optional. Launcher mode is not available yet.").font(.callout).foregroundStyle(.secondary)
                }.padding(18)
            }
            }
            }.frame(maxHeight: 500)
            if let validation { Text(validation).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Open Log Folder") { NSWorkspace.shared.open(store.stateDirectory) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var candidate = store.policy; candidate.default_mode = defaultMode; candidate.default_zone = zone
                    if store.save(candidate) && store.saveDisplayPreferences(display) { dismiss() }
                    else { validation = store.errorMessage; store.errorMessage = nil }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540)
        .onAppear {
            defaultMode = store.policy.default_mode; zone = store.policy.default_zone.isEmpty ? "Asia/Tokyo" : store.policy.default_zone
            display = store.displayPreferences
        }
    }

    private var previewPolicy: PolicyDocument {
        var candidate = store.policy; candidate.default_mode = defaultMode; candidate.default_zone = zone
        return candidate
    }
}

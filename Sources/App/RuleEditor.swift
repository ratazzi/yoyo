import SwiftUI
import AppKit
import ServiceManagement

private struct EnvironmentVariable: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

struct RuleEditor: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: ProgramRule
    @State private var validation: String?
    @State private var variables: [EnvironmentVariable]
    private let existing: Bool

    init(store: AppStore, initial: ProgramRule) {
        self.store = store; _rule = State(initialValue: initial)
        _variables = State(initialValue: initial.environment.keys.sorted().map { EnvironmentVariable(name: $0, value: initial.environment[$0]!) })
        existing = store.policy.rules.contains { $0.id == initial.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgramIcon(path: rule.pattern, kind: rule.kind, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(existing ? "Edit Program Rule" : "Add Program Rule").font(.headline)
                    Text("Choose this program’s time zone and environment.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Name", text: $rule.name)
                Picker("Program Type", selection: $rule.kind) {
                    Text("Application").tag("app"); Text("Command Line").tag("cli")
                }
                TextField(rule.kind == "app" ? "Application Path" : "Executable or Pattern", text: $rule.pattern)
                Picker("Time Zone", selection: $rule.mode) {
                    Text("System Default").tag("default")
                    Text("Fixed Time Zone").tag("fixed")
                    Text("Ask Every Launch").tag("ask")
                }
                if rule.mode != "default" {
                    LabeledContent(rule.mode == "ask" ? "Suggested Time Zone" : "Fixed Time Zone") {
                        TimeZoneField(selection: $rule.zone).frame(width: 230, height: 24)
                    }
                }
                Toggle("Enable this rule", isOn: $rule.enabled)
                Toggle("Record behavior to a log file", isOn: $rule.logging)
            }.formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Environment Variables").fontWeight(.medium)
                    Spacer()
                    Button { variables.append(EnvironmentVariable(name: "", value: "")) } label: {
                        Label("Add Variable", systemImage: "plus")
                    }.disabled(variables.count >= 64)
                }
                if !variables.isEmpty {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach($variables) { $variable in
                                HStack(spacing: 8) {
                                    TextField("Name", text: $variable.name).frame(width: 140)
                                        .accessibilityLabel("Variable name")
                                    TextField("Value", text: $variable.value).accessibilityLabel("Variable value")
                                    Button { variables.removeAll { $0.id == variable.id } } label: {
                                        Image(systemName: "minus.circle")
                                    }.buttonStyle(.plain).help("Remove variable").accessibilityLabel("Remove variable")
                                }
                            }
                        }
                    }.frame(height: min(CGFloat(variables.count) * 30, 120))
                }
                Text("Overrides existing values on next launch, including with System Default. Values are literal; $VARIABLE is not expanded. Child processes inherit them.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(rule.kind == "app" ? "Includes programs inside the application bundle. Explicit child rules take priority." : "Use an absolute path. * matches within one path component. Child processes inherit this launch choice.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if rule.logging {
                Text("Records process activity, file access, and time zone calls. File contents are never recorded.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let validation { Text(validation).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                if existing { Button("Delete Rule", role: .destructive) { store.removeRule(rule); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing ? "Save Changes" : "Add Rule") {
                    var environment: [String: String] = [:]
                    for variable in variables {
                        if variable.name.isEmpty && variable.value.isEmpty { continue }
                        if environment.updateValue(variable.value, forKey: variable.name) != nil {
                            validation = "Environment variable names must be unique."; return
                        }
                    }
                    rule.environment = environment
                    if store.saveRule(rule) { dismiss() }
                    else { validation = store.errorMessage; store.errorMessage = nil }
                }.keyboardShortcut(.defaultAction)
            }
        }.controlSize(.small).padding(16).frame(width: 480)
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updater: AppUpdater
    @Environment(\.dismiss) private var dismiss
    @State private var defaultMode = "system"
    @State private var zone = "Asia/Tokyo"
    @State private var validation: String?
    @State private var display = DisplayPreferences()
    @State private var favoriteZone = "Asia/Tokyo"
    @State private var clockFactory = ClockPresentationFactory()
    @State private var page = "Time Zones"
    @State private var updateChannel = UpdateChannel.stable
    @State private var automaticUpdates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
            Picker("Settings Section", selection: $page) {
                Text("Time Zones").tag("Time Zones")
                Text("Appearance").tag("Appearance")
                Text("Service").tag("Service")
                Text("Updates").tag("Updates")
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
            if page == "Updates" {
                Surface {
                    UpdatesView(updater: updater, channel: $updateChannel, automaticallyChecks: $automaticUpdates)
                        .padding(12)
                }
            }
            if page == "Time Zones" {
            Surface {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Time Zone").fontWeight(.semibold)
                    Picker("Use", selection: $defaultMode) {
                        Text("System Default").tag("system"); Text("Custom Time Zone").tag("fixed")
                    }
                    if defaultMode == "fixed" { TimeZoneField(selection: $zone).frame(height: 26) }
                    Text("For new programs without a rule. System Default rules exclude programs from injection.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            Surface {
                VStack(alignment: .leading, spacing: 8) {
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
                    Text("Switch the default time zone from the menu bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            }
            if page == "Appearance" {
            Surface {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Menu Bar & Dock").fontWeight(.semibold)
                    Picker("Menu Bar", selection: $display.menuBarContent) {
                        ForEach(ClockContent.allCases) { content in Text(content.title).tag(content) }
                    }
                    Toggle("Show Dock Icon", isOn: $display.showDockIcon).toggleStyle(.checkbox)
                    if display.showDockIcon {
                        Picker("Dock Time Zone", selection: $display.dockTimeZoneMode) {
                            Text("Follow Default Time Zone").tag(DockTimeZoneMode.followDefault)
                            Text("System Time Zone").tag(DockTimeZoneMode.system)
                            Text("Custom Time Zone").tag(DockTimeZoneMode.fixed)
                        }
                        if display.dockTimeZoneMode == .fixed {
                            TimeZoneField(selection: $display.dockTimeZone).frame(height: 26)
                        }
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
                        if display.showDockIcon {
                            let dock = clockFactory.makeDock(policy: previewPolicy, preferences: display, date: context.date)
                            HStack {
                                Text("Dock Preview").font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(dock.city) \(dock.time)").monospacedDigit().lineLimit(1)
                            }
                        }
                    }
                    Text("Menu bar text is hidden when the default matches the system.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            Surface {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show Time Zone Near Active Window", isOn: $display.showWindowBadge).toggleStyle(.checkbox)
                    Text("Requires Accessibility access and confirmed injection. Hidden in full screen; clicks pass through.")
                        .font(.caption).foregroundStyle(.secondary)
                    #if DEBUG
                    Toggle("Always Show Badge (Debug)", isOn: $display.debugAlwaysShowWindowBadge).toggleStyle(.checkbox)
                    Text("Shows Debug badges on visible windows with a known non-system launch time zone, including unfocused windows. Fully covered, minimized and other-desktop windows are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                    HStack {
                        Button("Preview Badge") { NotificationCenter.default.post(name: .init("PreviewWindowBadge"), object: nil) }
                        Button("Accessibility Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        Spacer()
                    }
                    Text(store.windowBadgeStatus).font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            }
            if page == "Service" {
            Surface {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Background Service").fontWeight(.semibold)
                            Text(store.online ? "Active · Applies rules from any launch source" : "Off · Rules are saved for later")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Enable Background Service", isOn: Binding(get: { store.policy.es_enabled }, set: { store.setServiceEnabled($0) })).toggleStyle(.switch).labelsHidden()
                    }
                    HStack {
                        Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        Button("Full Disk Access…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                    }
                    Text("Endpoint Security is optional. Launcher mode is not available yet.").font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            }
            }
            }.frame(height: page == "Service" ? 140 : (page == "Updates" ? 200 : (page == "Appearance" ? 320 : 300)))
            if let validation { Text(validation).foregroundStyle(.red).font(.callout) }
            HStack {
                if page == "Service" { Button("Open Log Folder") { NSWorkspace.shared.open(store.stateDirectory) } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if display.dockTimeZoneMode == .fixed && TimeZone(identifier: display.dockTimeZone) == nil {
                        validation = "Choose a valid Dock time zone."; return
                    }
                    var candidate = store.policy; candidate.default_mode = defaultMode; candidate.default_zone = zone
                    if store.save(candidate) && store.saveDisplayPreferences(display) {
                        if updater.channel != updateChannel { updater.channel = updateChannel }
                        if updater.automaticallyChecks != automaticUpdates { updater.automaticallyChecks = automaticUpdates }
                        dismiss()
                    }
                    else { validation = store.errorMessage; store.errorMessage = nil }
                }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 12)).controlSize(.small).padding(16).frame(width: 480)
        .onAppear {
            defaultMode = store.policy.default_mode; zone = store.policy.default_zone.isEmpty ? "Asia/Tokyo" : store.policy.default_zone
            display = store.displayPreferences
            updateChannel = updater.channel; automaticUpdates = updater.automaticallyChecks
        }
    }

    private var previewPolicy: PolicyDocument {
        var candidate = store.policy; candidate.default_mode = defaultMode; candidate.default_zone = zone
        return candidate
    }
}

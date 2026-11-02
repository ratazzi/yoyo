import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let store: AppStore
    private let applicationMenu: NSMenu
    private let openRule: (ProgramRule) -> Void
    private let clock = ClockPresentationFactory()
    private let rowSelection = MenuRowSelection()

    init(store: AppStore, applicationMenu: NSMenu, openRule: @escaping (ProgramRule) -> Void) {
        self.store = store; self.applicationMenu = applicationMenu; self.openRule = openRule
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        rowSelection.select(nil)
        let now = Date()
        let system = TimeZone.autoupdatingCurrent
        let current = store.policy.default_mode == "fixed" ? TimeZone(identifier: store.policy.default_zone) ?? system : system
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = store.displayPreferences.use24HourTime ? "HH:mm" : "h:mm a"
        func zoneItem(_ zone: TimeZone, name: String, value: String, icon: NSImage?) -> NSMenuItem {
            formatter.timeZone = zone
            let time = formatter.string(from: now)
            let offset = MenuTimeZone.offset(for: zone, at: now)
            let entry = action("\(name)  \(time)  \(offset)", #selector(selectZone), value: value)
            entry.toolTip = "\(zone.identifier) · UTC\(offset)"
            let view = MenuRowView(name: name, detail: .timeZone(time: time, offset: offset), icon: icon, selection: rowSelection)
            view.item = entry; view.toolTip = entry.toolTip; entry.view = view
            return entry
        }
        menu.addItem(.sectionHeader(title: "Default Time Zone"))
        let systemItem = zoneItem(system, name: "System Default", value: "system", icon: symbol("desktopcomputer", description: "System Time Zone"))
        systemItem.state = store.policy.default_mode != "fixed" ? .on : .off
        menu.addItem(systemItem)
        var favorites = store.displayPreferences.favoriteTimeZones.filter { TimeZone(identifier: $0) != nil }
        if store.policy.default_mode == "fixed", !favorites.contains(current.identifier) { favorites.insert(current.identifier, at: 0) }
        for identifier in favorites {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            let entry = zoneItem(zone, name: city(identifier), value: identifier, icon: symbol("clock", description: identifier))
            entry.state = store.policy.default_mode == "fixed" && current.identifier == identifier ? .on : .off
            menu.addItem(entry)
        }
        if store.policy.default_mode == "fixed" && !store.displayPreferences.favoriteTimeZones.contains(current.identifier) {
            let favorite = action("Favorite Current Time Zone", #selector(addFavorite), value: current.identifier)
            favorite.image = symbol("star", description: "Add Favorite")
            menu.addItem(favorite)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Program Overrides"))
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
        let overrides = MenuProgramOverrides.rows(policy: store.policy, runningAppPaths: running, system: system, clock: clock)
        if overrides.isEmpty {
            let empty = NSMenuItem(title: "No different time zones", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        for row in overrides.prefix(8) { menu.addItem(ruleItem(row)) }
        if overrides.count > 8 {
            let more = NSMenuItem(title: "More Programs (\(overrides.count - 8))", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.delegate = rowSelection
            for row in overrides.dropFirst(8) { submenu.addItem(ruleItem(row)) }
            more.submenu = submenu; menu.addItem(more)
        }
        let note = NSMenuItem(title: store.online ? "Changes apply on next launch" : "Background service is off", action: nil, keyEquivalent: "")
        note.isEnabled = false; menu.addItem(note)
        menu.addItem(.separator())
        for entry in applicationMenu.items {
            let copy = entry.copy() as! NSMenuItem
            let icons = ["Open Yoyo": "macwindow", "Settings…": "gearshape", "Find Program…": "magnifyingglass", "Quit Yoyo": "power"]
            if let name = icons[entry.title] { copy.image = symbol(name, description: entry.title) }
            menu.addItem(copy)
        }
        showImages(in: menu)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        rowSelection.select(item?.view as? MenuRowView)
    }

    func menuDidClose(_ menu: NSMenu) { rowSelection.select(nil) }

    private func showImages(in menu: NSMenu) {
        for entry in menu.items {
            // macOS 27 hides menu images by default, even when image is set.
            if #available(macOS 27.0, *), entry.image != nil {
                entry.preferredImageVisibility = .visible
            }
            if let submenu = entry.submenu { showImages(in: submenu) }
        }
    }

    private func symbol(_ name: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        image?.size = NSSize(width: 20, height: 20)
        image?.isTemplate = true
        return image
    }

    private func city(_ identifier: String) -> String {
        String(identifier.split(separator: "/").last ?? Substring(identifier)).replacingOccurrences(of: "_", with: " ")
    }

    private func action(_ title: String, _ selector: Selector, value: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self; entry.representedObject = value
        return entry
    }

    private func ruleItem(_ row: MenuProgramOverride) -> NSMenuItem {
        let rule = row.rule
        let zone = rule.mode == "fixed" ? city(rule.zone) : rule.summary
        let title = "\(rule.title), \(zone)"
        let entry = action(title, #selector(editRule), value: rule.id)
        entry.setAccessibilityLabel(title + (row.running ? ", Running" : ""))
        entry.toolTip = "\(rule.pattern)\n\(rule.summary)\n\(row.running ? "Running application. " : "")Configured rule; existing processes keep their launch time zone."
        let image = ProgramIcons.image(path: rule.pattern, kind: rule.kind).copy() as? NSImage
        let view = MenuRowView(name: rule.title, detail: .program(zone: zone, running: row.running), icon: image, selection: rowSelection)
        view.item = entry; view.toolTip = entry.toolTip
        entry.view = view
        return entry
    }

    @objc private func selectZone(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        var updated = store.policy
        updated.default_mode = identifier == "system" ? "system" : "fixed"
        if identifier != "system" { updated.default_zone = identifier }
        store.save(updated)
    }

    @objc private func addFavorite(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        var updated = store.displayPreferences
        if !updated.favoriteTimeZones.contains(identifier) { updated.favoriteTimeZones.append(identifier) }
        store.saveDisplayPreferences(updated)
    }

    @objc private func editRule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let rule = store.policy.rules.first(where: { $0.id == id }) else { return }
        openRule(rule)
    }
}

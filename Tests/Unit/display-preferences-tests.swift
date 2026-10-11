import Foundation

@main
struct DisplayPreferencesTests {
    static func main() throws {
        let clock = ClockPresentationFactory()
        var policy = PolicyDocument(); var preferences = DisplayPreferences()
        let epoch = Date(timeIntervalSince1970: 0)
        let system = TimeZone(identifier: "America/New_York")!
        assert(clock.make(policy: policy, preferences: preferences, date: epoch, system: system).label(for: .timeAndCity) == nil)
        policy.default_mode = "fixed"; policy.default_zone = "Asia/Tokyo"
        let tokyo = clock.make(policy: policy, preferences: preferences, date: epoch, system: system)
        assert(tokyo.time == "09:00" && tokyo.city == "Tokyo" && tokyo.label(for: .timeAndCity) == "Tokyo 09:00")
        assert(tokyo.label(for: .iconOnly) == nil && tokyo.label(for: .city) == "Tokyo")
        policy.default_zone = "Japan"
        assert(clock.make(policy: policy, preferences: preferences, date: epoch, system: TimeZone(identifier: "Asia/Tokyo")!).matchesSystem)
        assert(clock.make(policy: policy, preferences: preferences, date: epoch, system: system).city == "Tokyo")
        policy.default_zone = "Europe/London"
        let winter = Date(timeIntervalSince1970: 1704067200)
        assert(!clock.make(policy: policy, preferences: preferences, date: winter, system: TimeZone(identifier: "Etc/UTC")!).matchesSystem)
        policy.default_zone = "America/New_York"
        let summer = Date(timeIntervalSince1970: 1719835200) // 2024-07-01 12:00 UTC
        assert(MenuTimeZone.offset(for: TimeZone(identifier: "America/New_York")!, at: winter) == "−05")
        assert(MenuTimeZone.offset(for: TimeZone(identifier: "America/New_York")!, at: summer) == "−04")
        assert(MenuTimeZone.offset(for: TimeZone(identifier: "Asia/Tokyo")!, at: summer) == "+09")
        assert(MenuTimeZone.offset(for: TimeZone(identifier: "Asia/Kathmandu")!, at: summer) == "+05:45")
        assert(MenuTimeZone.offset(for: TimeZone(identifier: "Australia/Adelaide")!, at: summer) == "+09:30")
        assert(MenuTimeZone.offset(for: TimeZone(identifier: "Etc/UTC")!, at: summer) == "+00")
        assert(clock.make(policy: policy, preferences: preferences, date: summer, system: TimeZone(identifier: "Asia/Tokyo")!).time == "08:00")
        preferences.use24HourTime = false; preferences.showSeconds = true
        assert(clock.make(policy: policy, preferences: preferences, date: summer, system: TimeZone(identifier: "Asia/Tokyo")!).time == "8:00:00 AM")
        policy.default_zone = "America/Argentina/Buenos_Aires"
        assert(clock.make(policy: policy, preferences: preferences, date: epoch, system: system).city == "Buenos Aires")
        preferences.showDockIcon = true; preferences.dockContent = .city
        preferences.showWindowBadge = true
        preferences.favoriteTimeZones = ["Asia/Hong_Kong", "Etc/UTC"]
        let restored = try JSONDecoder().decode(DisplayPreferences.self, from: JSONEncoder().encode(preferences))
        let defaults = try JSONDecoder().decode(DisplayPreferences.self, from: Data("{}".utf8))
        assert(restored == preferences && defaults == DisplayPreferences())
        var menuPolicy = PolicyDocument()
        menuPolicy.default_mode = "fixed"; menuPolicy.default_zone = "Asia/Tokyo"
        var same = ProgramRule(); same.name = "Same"; same.mode = "fixed"; same.zone = "Japan"
        var app = ProgramRule(); app.name = "Running"; app.kind = "app"; app.pattern = "/Applications/Test.app"; app.mode = "fixed"; app.zone = "Europe/London"
        var excluded = ProgramRule(); excluded.name = "Excluded"; excluded.mode = "default"
        var disabled = app; disabled.id = "disabled"; disabled.enabled = false
        var ask = ProgramRule(); ask.name = "Ask"; ask.mode = "ask"
        menuPolicy.rules = [same, app, excluded, disabled, ask]
        let rows = MenuProgramOverrides.rows(policy: menuPolicy, runningAppPaths: [app.pattern], system: system, clock: clock)
        assert(rows.map { $0.rule.name } == ["Running", "Ask", "Excluded"])
        assert(rows[0].running && !rows[1].running && !rows[2].running)
        menuPolicy.default_mode = "system"
        assert(!MenuProgramOverrides.rows(policy: menuPolicy, runningAppPaths: [], system: system, clock: clock).contains { $0.rule.id == excluded.id })
        print("Clock display: system suppression, aliases, distinct DST rules, city names, formats, Dock settings and persistence: PASS")
        print("Menu overrides: aliases, system exclusions, disabled rules, ask mode and running app priority: PASS")
    }
}

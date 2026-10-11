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
        assert(clock.make(policy: policy, preferences: preferences, date: summer, system: TimeZone(identifier: "Asia/Tokyo")!).time == "08:00")
        preferences.use24HourTime = false; preferences.showSeconds = true
        assert(clock.make(policy: policy, preferences: preferences, date: summer, system: TimeZone(identifier: "Asia/Tokyo")!).time == "8:00:00 AM")
        policy.default_zone = "America/Argentina/Buenos_Aires"
        assert(clock.make(policy: policy, preferences: preferences, date: epoch, system: system).city == "Buenos Aires")
        preferences.showDockIcon = true; preferences.dockContent = .city
        let restored = try JSONDecoder().decode(DisplayPreferences.self, from: JSONEncoder().encode(preferences))
        let defaults = try JSONDecoder().decode(DisplayPreferences.self, from: Data("{}".utf8))
        assert(restored == preferences && defaults == DisplayPreferences())
        print("Clock display: system suppression, aliases, distinct DST rules, city names, formats, Dock settings and persistence: PASS")
    }
}

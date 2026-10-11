import Foundation

enum ClockContent: String, Codable, CaseIterable, Identifiable {
    case iconOnly, time, city, timeAndCity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconOnly: return "Icon Only"
        case .time: return "Time"
        case .city: return "City"
        case .timeAndCity: return "City and Time"
        }
    }
}

struct DisplayPreferences: Codable, Equatable {
    var menuBarContent: ClockContent = .timeAndCity
    var showDockIcon = false
    var dockContent: ClockContent = .timeAndCity
    var use24HourTime = true
    var showSeconds = false
    var showWindowBadge = false
    var favoriteTimeZones = ["Etc/UTC", "Asia/Tokyo", "America/New_York", "Europe/London"]

    init() {}
    private enum CodingKeys: String, CodingKey { case menuBarContent, showDockIcon, dockContent, use24HourTime, showSeconds, favoriteTimeZones, showWindowBadge }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        menuBarContent = try values.decodeIfPresent(ClockContent.self, forKey: .menuBarContent) ?? .timeAndCity
        showDockIcon = try values.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        dockContent = try values.decodeIfPresent(ClockContent.self, forKey: .dockContent) ?? .timeAndCity
        use24HourTime = try values.decodeIfPresent(Bool.self, forKey: .use24HourTime) ?? true
        showSeconds = try values.decodeIfPresent(Bool.self, forKey: .showSeconds) ?? false
        showWindowBadge = try values.decodeIfPresent(Bool.self, forKey: .showWindowBadge) ?? false
        favoriteTimeZones = try values.decodeIfPresent([String].self, forKey: .favoriteTimeZones) ?? ["Etc/UTC", "Asia/Tokyo", "America/New_York", "Europe/London"]
    }
}

struct ClockPresentation: Equatable {
    var time: String
    var city: String
    var zoneIdentifier: String
    var matchesSystem: Bool
    var tooltip: String

    func label(for content: ClockContent) -> String? {
        guard !matchesSystem else { return nil }
        switch content {
        case .iconOnly: return nil
        case .time: return time
        case .city: return city
        case .timeAndCity: return "\(city) \(time)"
        }
    }
}

final class ClockPresentationFactory {
    private let formatter = DateFormatter()
    private let detailFormatter = DateFormatter()
    private var identities: [String: String] = [:]
    private var formatKey = ""

    init() {
        formatter.locale = Locale(identifier: "en_US_POSIX")
        detailFormatter.locale = Locale(identifier: "en_US_POSIX")
        detailFormatter.dateStyle = .full
        detailFormatter.timeStyle = .long
    }

    private func identity(_ zone: TimeZone) -> String {
        if let cached = identities[zone.identifier] { return cached }
        let path = URL(fileURLWithPath: "/var/db/timezone/zoneinfo").appendingPathComponent(zone.identifier)
            .resolvingSymlinksInPath().path
        var canonical = path.range(of: "/zoneinfo/", options: .backwards).map { String(path[$0.upperBound...]) } ?? zone.identifier
        // Some macOS tzdata aliases are separate files instead of symlinks.
        var output = [CChar](repeating: 0, count: 256)
        if zone.identifier.withCString({ timezone_display_canonicalize($0, &output, output.count) }) != 0 {
            canonical = String(cString: output)
        }
        identities[zone.identifier] = canonical
        return canonical
    }

    func make(policy: PolicyDocument, preferences: DisplayPreferences, date: Date = Date(), system: TimeZone = .autoupdatingCurrent) -> ClockPresentation {
        let zone = policy.default_mode == "fixed" ? TimeZone(identifier: policy.default_zone) ?? system : system
        let canonical = identity(zone)
        let key = "\(zone.identifier):\(preferences.use24HourTime):\(preferences.showSeconds)"
        if key != formatKey {
            formatter.timeZone = zone
            formatter.dateFormat = preferences.use24HourTime
                ? (preferences.showSeconds ? "HH:mm:ss" : "HH:mm")
                : (preferences.showSeconds ? "h:mm:ss a" : "h:mm a")
            detailFormatter.timeZone = zone
            formatKey = key
        }
        let city = String(canonical.split(separator: "/").last ?? Substring(canonical)).replacingOccurrences(of: "_", with: " ")
        let matchesSystem = policy.default_mode != "fixed" || canonical == identity(system) || (zone as NSTimeZone).data == (system as NSTimeZone).data
        return ClockPresentation(time: formatter.string(from: date), city: city, zoneIdentifier: canonical, matchesSystem: matchesSystem,
            tooltip: matchesSystem ? "Timezone Lab · System Default\n\(system.identifier)" : "\(city) · \(canonical)\n\(detailFormatter.string(from: date))")
    }
}

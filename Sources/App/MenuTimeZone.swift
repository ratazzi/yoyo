import Foundation

enum MenuTimeZone {
    struct Usage {
        var zone: TimeZone
        var rules: [ProgramRule] = []
        var isDefault = false
    }

    static func configured(policy: PolicyDocument, system: TimeZone, clock: ClockPresentationFactory) -> [Usage] {
        var groups = [Usage(zone: system)]
        func group(for zone: TimeZone) -> Int {
            var candidate = PolicyDocument()
            candidate.default_mode = "fixed"; candidate.default_zone = zone.identifier
            if let index = groups.firstIndex(where: {
                clock.make(policy: candidate, preferences: DisplayPreferences(), system: $0.zone).matchesSystem
            }) { return index }
            let canonical = clock.make(policy: candidate, preferences: DisplayPreferences(), system: system).zoneIdentifier
            groups.append(Usage(zone: TimeZone(identifier: canonical) ?? zone))
            return groups.count - 1
        }
        let defaultZone = policy.default_mode == "fixed" ? TimeZone(identifier: policy.default_zone) ?? system : system
        let defaultIndex = group(for: defaultZone)
        groups[defaultIndex].isDefault = true
        for rule in policy.rules where rule.enabled && rule.mode != "ask" {
            guard let zone = rule.mode == "fixed" ? TimeZone(identifier: rule.zone) : system else { continue }
            let index = group(for: zone)
            groups[index].rules.append(rule)
        }
        return [groups[0]] + groups.dropFirst().sorted { $0.zone.identifier.localizedStandardCompare($1.zone.identifier) == .orderedAscending }
    }

    static func offset(for zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let minutes = abs(seconds) / 60
        let sign = seconds < 0 ? "−" : "+"
        let fraction = minutes % 60 == 0 ? "" : String(format: ":%02d", minutes % 60)
        return "\(sign)\(String(format: "%02d", minutes / 60))\(fraction)"
    }
}

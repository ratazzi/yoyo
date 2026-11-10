import Foundation

struct MenuProgramOverride {
    var rule: ProgramRule
    var running: Bool
}

enum MenuProgramOverrides {
    static func rows(policy: PolicyDocument, runningAppPaths: [String], system: TimeZone, clock: ClockPresentationFactory) -> [MenuProgramOverride] {
        let defaultZone = policy.default_mode == "fixed" ? TimeZone(identifier: policy.default_zone) ?? system : system
        return policy.rules.compactMap { rule -> MenuProgramOverride? in
            guard rule.enabled else { return nil }
            if rule.mode != "ask" && rule.environment.isEmpty {
                var candidate = PolicyDocument()
                candidate.default_mode = "fixed"
                candidate.default_zone = rule.mode == "fixed" ? rule.zone : system.identifier
                if clock.make(policy: candidate, preferences: DisplayPreferences(), system: defaultZone).matchesSystem { return nil }
            }
            let path = URL(fileURLWithPath: rule.pattern).resolvingSymlinksInPath().path
            return MenuProgramOverride(rule: rule, running: rule.kind == "app" && runningAppPaths.contains(path))
        }.sorted {
            if $0.running != $1.running { return $0.running }
            return $0.rule.title.localizedStandardCompare($1.rule.title) == .orderedAscending
        }
    }
}

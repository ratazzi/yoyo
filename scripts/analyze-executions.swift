import Foundation

struct ProcessInfo: Decodable {
    var id: String?
    var pid: Int?
    var path: String?
    var started_at: Double?
    var parent_id: String?
}
struct Execution: Decodable {
    var time: Double
    var process: ProcessInfo
    var parent: ProcessInfo
    var responsible: ProcessInfo
    var ancestors: [ProcessInfo]?
}
let wrappers: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "env", "nohup", "login", "xpcproxy", "launchd", "runningboardd", "launchservicesd"]
func appBundle(_ path: String) -> String? {
    var prefix = ""
    for component in (path as NSString).pathComponents {
        prefix = (prefix as NSString).appendingPathComponent(component)
        if (component as NSString).pathExtension.lowercased() == "app" { return prefix }
    }
    return nil
}
func owner(_ event: Execution, byID: [String: Execution], visited: Set<String> = []) -> (String, String) {
    var seen = visited
    if let id = event.process.id { seen.insert(id) }
    if let path = event.responsible.path, !path.isEmpty, event.responsible.id != event.process.id,
       !wrappers.contains((path as NSString).lastPathComponent) {
        return (appBundle(path) ?? path, "responsible")
    }
    if let path = event.parent.path, let app = appBundle(path) { return (app, "parent") }
    for ancestor in event.ancestors ?? [] {
        if let path = ancestor.path, !path.isEmpty, !wrappers.contains((path as NSString).lastPathComponent) {
            return (appBundle(path) ?? path, "audit-parent-chain")
        }
    }
    if let id = event.parent.id, !seen.contains(id), let parentEvent = byID[id], seen.count < 16 {
        let root = owner(parentEvent, byID: byID, visited: seen)
        return (root.0, "parent-chain")
    }
    if let path = event.parent.path, !path.isEmpty, event.parent.pid != 1 {
        return (appBundle(path) ?? path, "parent/unresolved-root")
    }
    let path = event.process.path ?? "Unknown"
    return (appBundle(path) ?? path, "self/unresolved")
}
guard CommandLine.arguments.count >= 2 else { fatalError("usage: analyze-executions input.jsonl [report.md]") }
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
var malformed = 0
let events = data.split(separator: 10).compactMap { line -> Execution? in
    do { return try JSONDecoder().decode(Execution.self, from: Data(line)) }
    catch { malformed += 1; return nil }
}
let byID = Dictionary(events.compactMap { event in event.process.id.map { ($0, event) } }, uniquingKeysWith: { _, newer in newer })
let groups = Dictionary(grouping: events) { owner($0, byID: byID).0 }.sorted { $0.value.count > $1.value.count }
let start = events.map(\.time).min() ?? 0, end = events.map(\.time).max() ?? 0
var report = "# Execution activity sample\n\n"
report += "Observed span: \(String(format: "%.1f", end - start)) seconds. Captured exec events: \(events.count). Malformed lines: \(malformed).\n\n"
report += "Scope: current-user exec events, excluding this app and daemon. No arguments, environment variables or file contents. Exec counts include multiple image replacements in one PID.\n\n"
report += "| Owner (responsible, then parent, then self) | Exec events | Distinct PIDs | Frequent executables |\n|---|---:|---:|---|\n"
for (name, group) in groups {
    let commands = Dictionary(grouping: group) { $0.process.path ?? "Unknown" }.sorted { $0.value.count > $1.value.count }
    let common = commands.prefix(6).map { "\(($0.key as NSString).lastPathComponent) ×\($0.value.count)" }.joined(separator: ", ")
    report += "| \(name.replacingOccurrences(of: "|", with: "\\|")) | \(group.count) | \(Set(group.compactMap { $0.process.pid }).count) | \(common) |\n"
}
report += "\n## Attribution and timing\n\n"
for (name, group) in groups.prefix(12) {
    let attribution = Dictionary(grouping: group) { owner($0, byID: byID).1 }.map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
    report += "### \(name)\n\n\(attribution)\n\n"
    let commands = Dictionary(grouping: group) { $0.process.path ?? "Unknown" }.sorted { $0.value.count > $1.value.count }
    for (command, samples) in commands.prefix(8) {
        let times = samples.map(\.time).sorted()
        let deltas = zip(times.dropFirst(), times).map(-).sorted()
        let interval = deltas.isEmpty ? "n/a" : String(format: "%.2fs", deltas[deltas.count / 2])
        let parents = Array(Set(samples.compactMap { $0.parent.path })).sorted().map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        report += "- `\(command)`: \(samples.count) execs; median interval \(interval); parents: \(parents)\n"
    }
    report += "\n"
}
if CommandLine.arguments.count > 2 { try report.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8) }
print(report)

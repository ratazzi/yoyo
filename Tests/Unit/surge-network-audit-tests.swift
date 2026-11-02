import Foundation

@main
enum SurgeNetworkAuditTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = SurgeNetworkAudit(directory: directory, maximumBytes: 500)
        let report: [String: Any] = ["received_at": 123.0, "request": ["hostname": "example.test", "argument": "Paris"],
            "timezone": "Europe/Paris", "matched": false]
        var session: [String: Any] = ["pid": 42, "parent_pid": 41, "session": "launch-id", "logging": false,
            "baseline": ["secret": "excluded"]]
        let path = directory.appendingPathComponent("network-audit.jsonl")
        audit.record(report: report, session: session, identityIsCurrent: true)
        session["logging"] = true
        audit.record(report: report, session: session, identityIsCurrent: false)
        audit.flush()
        assert(!FileManager.default.fileExists(atPath: path.path))
        audit.record(report: report, session: session, identityIsCurrent: true)
        audit.flush()
        let data = try Data(contentsOf: path)
        let event = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let process = event["process"] as! [String: Any]
        assert(process["session"] as? String == "launch-id" && process["parent_pid"] as? Int == 41)
        assert(process["baseline"] == nil && event["matched"] as? Bool == false)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        assert(attributes[.posixPermissions] as? Int == 0o600)
        for _ in 0..<4 { audit.record(report: report, session: session, identityIsCurrent: true) }
        audit.flush()
        assert(FileManager.default.fileExists(atPath: path.appendingPathExtension("1").path))
        for file in [path, path.appendingPathExtension("1")] {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
            }
        }
        print("Surge audit: opt-in, trusted identity, session correlation, private append and rotation: PASS")
    }
}

import Foundation
import Darwin

// One record per SCRIPT evaluation, correlated by the daemon's launch-session identity.
final class SurgeNetworkAudit {
    private let queue = DispatchQueue(label: "yoyo.network-audit")
    private let slots = DispatchSemaphore(value: 128)
    private let url: URL
    private let maximumBytes: Int

    init(directory: URL, maximumBytes: Int = 5 * 1024 * 1024) {
        url = directory.appendingPathComponent("network-audit.jsonl")
        self.maximumBytes = maximumBytes
    }

    func record(report: [String: Any], session: [String: Any]?, identityIsCurrent: Bool) {
        guard identityIsCurrent, let session, session["logging"] as? Bool == true else { return }
        let fields = ["pid", "pidversion", "parent_pid", "path", "started_at", "session", "rule_id", "mode", "zone", "confirmation"]
        let event: [String: Any] = ["event": "surge_rule_evaluation", "received_at": report["received_at"] ?? NSNull(),
            "request": report["request"] ?? [:], "process": session.filter { fields.contains($0.key) },
            "timezone": report["timezone"] ?? NSNull(), "matched": report["matched"] ?? false,
            "routing": report["routing"] ?? [:]]
        guard slots.wait(timeout: .now()) == .success else {
            FileHandle.standardError.write(Data("Network audit queue full; evaluation dropped\n".utf8)); return
        }
        queue.async {
            defer { self.slots.signal() }
            do {
                var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                data.append(10)
                let manager = FileManager.default
                if let size = try? manager.attributesOfItem(atPath: self.url.path)[.size] as? Int,
                   size + data.count > self.maximumBytes {
                    let backup = self.url.appendingPathExtension("1")
                    if manager.fileExists(atPath: backup.path) { try manager.removeItem(at: backup) }
                    try manager.moveItem(at: self.url, to: backup)
                }
                let fd = open(self.url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? file.close() }
                try file.write(contentsOf: data)
            } catch { FileHandle.standardError.write(Data("Network audit: \(error)\n".utf8)) }
        }
    }

    func flush() { queue.sync {} }
}

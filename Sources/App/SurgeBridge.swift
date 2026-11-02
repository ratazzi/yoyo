import Foundation
import Network
import Darwin

// Loopback-only timezone matching and audit. Surge owns policy selection.
final class SurgeBridge {
    private let queue = DispatchQueue(label: "yoyo.surge-bridge")
    private let listener: NWListener
    private var latest: [String: Any] = [:]
    private let sessionLookup: (Int) -> [String: Any]?
    private let audit: SurgeNetworkAudit?
    private var sessionCache: [String: (value: [String: Any]?, at: Double)] = [:]

    init(port: UInt16 = 47643, auditDirectory: URL? = nil, sessionLookup: ((Int) -> [String: Any]?)? = nil) throws {
        self.sessionLookup = sessionLookup ?? Self.querySignedInspector
        audit = auditDirectory.map { SurgeNetworkAudit(directory: $0) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: print("Yoyo Surge bridge: http://127.0.0.1:\(port)/v1/surge/request"); fflush(stdout)
            case .failed(let error): print("Surge bridge listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
            self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel(); audit?.flush() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 20480 else { self.respond(connection, status: 413, value: ["error": "request_too_large"]); return }
            guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() }
                else { self.receive(connection, buffer: buffer) }
                return
            }
            guard split.lowerBound <= 4096, let header = String(data: buffer[..<split.lowerBound], encoding: .utf8) else {
                self.respond(connection, status: 400, value: ["error": "invalid_headers"]); return
            }
            let lines = header.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                if pair.count == 2 { headers[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
            }
            // Reject browser-origin calls and preflight; this endpoint is for local Surge only.
            guard headers["origin"] == nil, headers["transfer-encoding"] == nil else {
                self.respond(connection, status: 403, value: ["error": "unsupported_origin_or_encoding"]); return
            }
            if lines.first == "GET /health HTTP/1.1" {
                self.respond(connection, status: 200, value: ["service": "yoyo-surge-bridge", "ok": true]); return
            }
            if lines.first == "GET /v1/surge/latest HTTP/1.1" {
                self.respond(connection, status: 200, value: self.latest); return
            }
            guard lines.first == "POST /v1/surge/request HTTP/1.1",
                  headers["content-type"]?.hasPrefix("application/json") == true,
                  let length = headers["content-length"].flatMap(Int.init), length >= 0, length <= 16384 else {
                self.respond(connection, status: 400, value: ["error": "expected_json_post"]); return
            }
            guard buffer.count - split.upperBound >= length else {
                if complete || error != nil { connection.cancel() }
                else { self.receive(connection, buffer: buffer) }
                return
            }
            let body = buffer.subdata(in: split.upperBound..<(split.upperBound + length))
            guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                self.respond(connection, status: 400, value: ["error": "invalid_json"]); return
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result = TZSurgeSocketCandidates(request) as? [String: Any] ?? [:]
            let fields = ["argument", "hostname", "destPort", "sourcePort", "protocol", "processPath", "sourceIP", "listenPort", "dnsResult"]
            let summary = request.filter { fields.contains($0.key) }
            let candidate = (result["candidates"] as? [[String: Any]])?.first { $0["pid"] as? Int == result["pid"] as? Int }
            let session = result["status"] as? String == "socket_unique" ? candidate.flatMap(self.launchSession) : nil
            let current = candidate.flatMap { candidate in session.map { TZSurgeSessionIsCurrent(candidate, $0) } } ?? false
            let decision = SurgeTimezoneRouting.decide(socket: result, session: session, identityIsCurrent: current)
            self.latest = ["received_at": Date().timeIntervalSince1970, "request": summary, "result": result,
                "timezone": decision.zone as Any? ?? NSNull(), "matched": decision.matches(argument: request["argument"]), "routing": decision.json,
                "lookup_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000]
            print("Surge bridge: \(decision.reason), zone=\(decision.zone ?? "unknown"), pid=\(result["pid"] ?? NSNull())")
            fflush(stdout)
            self.respond(connection, status: 200, value: self.latest)
            self.audit?.record(report: self.latest, session: session, identityIsCurrent: current)
        }
    }

    private func launchSession(_ candidate: [String: Any]) -> [String: Any]? {
        guard let pid = candidate["pid"] as? Int else { return nil }
        let key = "\(pid):\(candidate["path"] ?? ""):\(candidate["started_at"] ?? "")"
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = sessionCache[key], now - cached.at < 0.5 {
            if cached.value == nil || cached.value?["_lookup_error"] != nil { return cached.value }
            if let value = cached.value, TZSurgeSessionIsCurrent(candidate, value) { return value }
        }
        let session = sessionLookup(pid)
        if sessionCache.count >= 128 { sessionCache.removeAll() }
        sessionCache[key] = (session, now)
        return session
    }

    private static func querySignedInspector(pid: Int) -> [String: Any]? {
        let bundle = ProcessInfo.processInfo.environment["YOYO_APP_BUNDLE"]
            ?? FileManager.default.currentDirectoryPath + "/build/Yoyo.app"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/MacOS/Yoyo")
        task.arguments = ["--inspect-process", String(pid)]
        let output = Pipe(); task.standardOutput = output; task.standardError = Pipe()
        do { try task.run() }
        catch { return ["_lookup_error": "inspector_unavailable"] }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
        if task.isRunning {
            task.terminate(); Thread.sleep(forTimeInterval: 0.01)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            return ["_lookup_error": "inspector_timeout"]
        }
        task.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], response["error"] == nil else {
            return ["_lookup_error": "inspector_failed"]
        }
        return response["process"] as? [String: Any]
    }

    private func respond(_ connection: NWConnection, status: Int, value: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

#if SURGE_BRIDGE_STANDALONE
@main
enum SurgeBridgeMain {
    static func main() throws {
        let port = CommandLine.arguments.dropFirst().first.flatMap(UInt16.init) ?? 47643
        let server = try SurgeBridge(port: port)
        withExtendedLifetime(server) { dispatchMain() }
    }
}
#endif

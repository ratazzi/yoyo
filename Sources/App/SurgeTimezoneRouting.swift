import Foundation

struct SurgeRouteDecision {
    var reason: String
    var zone: String?
    var session: String?
    var confirmation: String?

    func matches(argument: Any?) -> Bool {
        guard let zone, let argument = argument as? String, !argument.isEmpty else { return false }
        return zone.split(separator: "/").last.map(String.init) == argument
    }

    var json: [String: Any] {
        ["zone": zone as Any? ?? NSNull(),
         "session": session as Any? ?? NSNull(), "confirmation": confirmation as Any? ?? NSNull(), "reason": reason]
    }
}

enum SurgeTimezoneRouting {
    static func decide(socket: [String: Any], session: [String: Any]?, identityIsCurrent: Bool) -> SurgeRouteDecision {
        guard socket["status"] as? String == "socket_unique", let pid = socket["pid"] as? Int,
              let candidates = socket["candidates"] as? [[String: Any]],
              let candidate = candidates.first(where: { $0["pid"] as? Int == pid }) else {
            let reason: String
            switch socket["status"] as? String {
            case "ambiguous": reason = "socket_not_unique"
            case "socket_candidate": reason = "socket_endpoint_unverified"
            case "inspection_limited": reason = "socket_inspection_limited"
            default: reason = "socket_unavailable"
            }
            return SurgeRouteDecision(reason: reason)
        }
        guard let session else { return SurgeRouteDecision(reason: "no_launch_session") }
        guard session["_lookup_error"] == nil else { return SurgeRouteDecision(reason: "session_lookup_failed") }
        guard session["pid"] as? Int == pid,
              let path = candidate["path"] as? String, let sessionPath = session["path"] as? String,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == URL(fileURLWithPath: sessionPath).resolvingSymlinksInPath().path,
              let started = candidate["started_at"] as? Double, let sessionStarted = session["started_at"] as? Double,
              abs(started - sessionStarted) < 0.001, identityIsCurrent else {
            return SurgeRouteDecision(reason: "process_or_socket_changed")
        }
        guard session["mode"] as? String == "fixed", let name = session["zone"] as? String,
              TimeZone(identifier: name) != nil, let identifier = session["session"] as? String, !identifier.isEmpty else {
            return SurgeRouteDecision(reason: "no_fixed_launch_zone")
        }
        return SurgeRouteDecision(reason: "launch_timezone", zone: name,
            session: identifier, confirmation: session["confirmation"] as? String)
    }
}

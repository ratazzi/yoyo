import Foundation

@main
enum SurgeTimezoneRoutingTests {
    static func main() {
        var socket: [String: Any] = ["status": "socket_unique", "pid": 42,
            "candidates": [["pid": 42, "path": "/test/client", "started_at": 100.0]]]
        var session: [String: Any] = ["pid": 42, "path": "/test/client", "started_at": 100.0,
            "mode": "fixed", "zone": "Europe/Paris", "session": "launch-session", "confirmation": "confirmed"]
        func decide(_ value: [String: Any]?, current: Bool = true) -> SurgeRouteDecision {
            SurgeTimezoneRouting.decide(socket: socket, session: value, identityIsCurrent: current)
        }
        assert(decide(session).zone == "Europe/Paris")
        assert(decide(session).matches(argument: "Paris"))
        for argument: Any in ["Los_Angeles", "", "paris", 123, NSNull()] {
            assert(!decide(session).matches(argument: argument))
        }
        assert(!decide(nil).matches(argument: "Paris"))
        session["zone"] = "Asia/Singapore"; assert(decide(session).zone == "Asia/Singapore")
        session["zone"] = "Europe/London"; assert(decide(session).zone == "Europe/London")
        session["zone"] = "Europe/Paris"
        assert(decide(nil).reason == "no_launch_session")
        assert(decide(session, current: false).zone == nil)
        session["pid"] = 43; assert(decide(session).reason == "process_or_socket_changed")
        session["pid"] = 42; session["started_at"] = 101.0; assert(decide(session).zone == nil)
        session["started_at"] = 100.0; session["path"] = "/test/other"; assert(decide(session).zone == nil)
        session["path"] = "/test/client"; session["mode"] = "default"; assert(decide(session).zone == nil)
        session["mode"] = "fixed"
        socket["status"] = "ambiguous"; assert(decide(session).reason == "socket_not_unique")
        socket["status"] = "socket_unique"
        for zone in ["America/Los_Angeles", "America/Argentina/Buenos_Aires", "Japan", "Etc/UTC"] {
            session["zone"] = zone; assert(decide(session).zone == zone)
        }
        session["zone"] = "Invalid/Zone"; assert(decide(session).zone == nil)
        print("Surge routing: PID launch identity, timezone-name convention and unmatched failure paths: PASS")
    }
}

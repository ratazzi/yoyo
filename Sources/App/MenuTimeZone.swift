import Foundation

enum MenuTimeZone {
    static func offset(for zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let minutes = abs(seconds) / 60
        let sign = seconds < 0 ? "−" : "+"
        let fraction = minutes % 60 == 0 ? "" : String(format: ":%02d", minutes % 60)
        return "UTC\(sign)\(minutes / 60)\(fraction)"
    }
}

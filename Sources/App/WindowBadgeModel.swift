import Foundation
import CoreGraphics

struct WindowBadgeProcess: Codable {
    var pid: Int
    var path: String
    var started_at: Double
    var mode: String
    var zone: String
    var loaded: Bool

    func confirmedZone(pid expectedPID: Int, executable: String, launchedAt: Double) -> TimeZone? {
        guard pid == expectedPID, loaded, mode == "fixed", abs(started_at - launchedAt) < 1,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == executable else { return nil }
        return TimeZone(identifier: zone)
    }
}

enum WindowBadgePlacement {
    static func frame(window: CGRect, size: CGSize, screens: [CGRect]) -> CGRect? {
        guard window.width > 0, window.height > 0, size.width > 0, size.height > 0,
              let screen = screens.max(by: { area($0.intersection(window)) < area($1.intersection(window)) }),
              area(screen.intersection(window)) > 0 else { return nil }
        let candidates = [
            CGRect(x: window.maxX - size.width - 8, y: window.maxY + 6, width: size.width, height: size.height),
            CGRect(x: window.maxX + 6, y: window.maxY - size.height - 8, width: size.width, height: size.height),
            CGRect(x: window.maxX - size.width - 8, y: window.minY - size.height - 6, width: size.width, height: size.height),
            CGRect(x: window.minX - size.width - 6, y: window.maxY - size.height - 8, width: size.width, height: size.height)
        ]
        return candidates.first { screen.insetBy(dx: 4, dy: 4).contains($0) && !$0.intersects(window) }
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}

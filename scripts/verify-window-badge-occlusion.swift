import AppKit

let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
let applications = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
let top = NSScreen.screens.first?.frame.maxY ?? 0
let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/state/window-badge-diagnostics.json")
let state = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
let badges = state["debug_badges"] as? [[String: Any]] ?? []
var overlaps: [[String: Any]] = []
var misplaced: [[String: Any]] = []
for badge in badges {
    guard let identity = badge["identity"] as? String, let target = identity.split(separator: ":").last.flatMap({ UInt32($0) }),
          let position = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target }),
          let bounds = badge["badge"] as? [String: Double], let x = bounds["x"], let y = bounds["y"],
          let width = bounds["width"], let height = bounds["height"] else { continue }
    let frame = CGRect(x: x, y: y, width: width, height: height)
    let targetBounds = windows[position][kCGWindowBounds as String] as! [String: Any]
    let targetRect = CGRect(dictionaryRepresentation: targetBounds as CFDictionary)!
    let ownerFrame = CGRect(x: targetRect.minX, y: top - targetRect.maxY, width: targetRect.width, height: targetRect.height)
    if frame.intersects(ownerFrame) { misplaced.append(badge) }
    if CommandLine.arguments.contains("--require-anchor") {
        let screen = NSScreen.screens.map(\.visibleFrame).max { a, b in
            let first = a.intersection(ownerFrame), second = b.intersection(ownerFrame)
            return (first.isNull ? 0 : first.width * first.height) < (second.isNull ? 0 : second.width * second.height)
        }
        let candidates = [
            CGRect(x: ownerFrame.maxX - width - 8, y: ownerFrame.maxY + 6, width: width, height: height),
            CGRect(x: ownerFrame.maxX + 6, y: ownerFrame.maxY - height - 8, width: width, height: height),
            CGRect(x: ownerFrame.maxX - width - 8, y: ownerFrame.minY - height - 6, width: width, height: height),
            CGRect(x: ownerFrame.minX - width - 6, y: ownerFrame.maxY - height - 8, width: width, height: height)]
        let expected = candidates.first { screen?.insetBy(dx: 4, dy: 4).contains($0) == true && !$0.intersects(ownerFrame) }
        if expected != frame { misplaced.append(badge) }
    }
    for (index, value) in windows.enumerated() where index != position {
        guard let pid = value[kCGWindowOwnerPID as String] as? Int, let layer = value[kCGWindowLayer as String] as? Int,
              !(value[kCGWindowOwnerName as String] as? String == "Yoyo" && layer == 3), layer >= 0,
              (value[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let bounds = value[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
        let other = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        if applications[pid_t(pid)]?.bundleIdentifier == "com.apple.dock", layer == Int(CGWindowLevelForKey(.dockWindow)),
           NSScreen.screens.contains(where: { $0.frame == other }) { continue }
        if frame.intersects(other) && (index < position || !ownerFrame.contains(frame)) {
            let app = applications[pid_t(pid)]
            overlaps.append(["badge": badge, "occluder_pid": pid, "occluder_layer": layer,
                "occluder_app": value[kCGWindowOwnerName as String] ?? "", "bundle": app?.bundleURL?.path ?? "missing",
                "rect": ["x": other.minX, "y": other.minY, "width": other.width, "height": other.height]])
        }
    }
}
let output: [String: Any] = ["badges_checked": badges.count, "overlaps": overlaps, "misplaced": misplaced]
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
exit(overlaps.isEmpty && misplaced.isEmpty && (!CommandLine.arguments.contains("--require-badges") || !badges.isEmpty) ? 0 : 1)

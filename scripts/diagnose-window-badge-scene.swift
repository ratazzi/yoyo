import AppKit

@main
enum BadgeSceneDiagnostic {
    static func main() throws {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map(\.visibleFrame)
        let rows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        func rect(_ frame: CGRect) -> [String: Double] {
            ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        }
        var surfaces: [WindowBadgeSurface] = []
        var metadata: [UInt32: [String: Any]] = [:]
        for row in rows {
            guard let layer = row[kCGWindowLayer as String] as? Int, layer >= 0,
                  let id = row[kCGWindowNumber as String] as? NSNumber,
                  !(row[kCGWindowOwnerName as String] as? String == "Yoyo" && layer == 3),
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let raw = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let frame = CGRect(x: raw.minX, y: top - raw.maxY, width: raw.width, height: raw.height)
            let pid = row[kCGWindowOwnerPID as String] as? Int ?? 0
            if WindowBadgeSurface.isDockDesktopSurface(bundleIdentifier: apps[pid_t(pid)]?.bundleIdentifier,
                layer: layer, dockLayer: Int(CGWindowLevelForKey(.dockWindow)), frame: frame, screens: NSScreen.screens.map(\.frame)) { continue }
            surfaces.append(WindowBadgeSurface(windowID: id.uint32Value, frame: frame))
            metadata[id.uint32Value] = ["id": id.uint32Value, "pid": row[kCGWindowOwnerPID as String] ?? 0,
                "owner": row[kCGWindowOwnerName as String] ?? "", "layer": layer, "frame": rect(frame)]
        }
        var targets: [[String: Any]] = []
        var sessions: [Int: [String: Any]] = [:]
        for surface in surfaces {
            guard let entry = metadata[surface.windowID], entry["layer"] as? Int == 0,
                  let pid = entry["pid"] as? Int, let app = apps[pid_t(pid)],
                  app.bundleURL?.pathExtension.lowercased() == "app", !app.isTerminated,
                  app.activationPolicy != .prohibited, let path = app.executableURL?.resolvingSymlinksInPath().path,
                  let launched = app.launchDate?.timeIntervalSince1970,
                  let context = WindowBadgeOcclusion(windowID: surface.windowID, surfaces: surfaces) else { continue }
            if sessions[pid] == nil {
                let task = Process(); task.executableURL = URL(fileURLWithPath: "build/Yoyo.app/Contents/MacOS/Yoyo")
                task.arguments = ["--inspect-process", String(pid)]
                let output = Pipe(); task.standardOutput = output; task.standardError = Pipe()
                try task.run(); task.waitUntilExit()
                let reply = (try? JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile())) as? [String: Any]
                sessions[pid] = reply?["process"] as? [String: Any] ?? [:]
            }
            guard let session = sessions[pid], let data = try? JSONSerialization.data(withJSONObject: session),
                  let process = try? JSONDecoder().decode(WindowBadgeProcess.self, from: data),
                  let zone = process.debugZone(pid: pid, executable: path, launchedAt: launched, system: .autoupdatingCurrent) else { continue }
            let size = CGSize(width: 180, height: 24)
            let placement = WindowBadgePlacement.debugFrame(window: surface.frame, size: size, screens: screens,
                occluders: context.foreground, neighbors: context.neighbors)
            let front = surfaces.prefix { $0.windowID != surface.windowID }.filter { $0.frame.intersects(surface.frame) }
            targets.append(["target": entry, "zone": zone.identifier, "placement": placement.map(rect) as Any? ?? NSNull(),
                "foreground_intersections": front.compactMap { metadata[$0.windowID] }])
        }
        let result: [String: Any] = ["screens": screens.map(rect), "surfaces": surfaces.compactMap { metadata[$0.windowID] }, "targets": targets]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "build/evidence/window-badge-scene.json"))
        let placed = targets.filter { !($0["placement"] is NSNull) }
        let mainPlaced = placed.filter { entry in
            guard let frame = entry["placement"] as? [String: Double] else { return false }
            return screens[0].intersects(CGRect(x: frame["x"]!, y: frame["y"]!, width: frame["width"]!, height: frame["height"]!))
        }
        if CommandLine.arguments.contains("--summary") {
            print("Eligible windows: \(targets.count), main-display placements: \(mainPlaced.count), all-display placements: \(placed.count)")
        } else {
            print(String(data: try JSONSerialization.data(withJSONObject: ["screens": screens.map(rect), "targets": targets], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        }
        if CommandLine.arguments.contains("--require-main") && mainPlaced.isEmpty {
            fputs("FAIL: no badge placement on the main display\n", stderr); exit(1)
        }
    }
}

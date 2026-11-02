import AppKit
import UniformTypeIdentifiers

@MainActor
enum ProgramIcons {
    private static let application = NSWorkspace.shared.icon(for: .applicationBundle)
    private static let terminal = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")

    static func image(path: String, kind: String? = nil) -> NSImage {
        if kind == "cli" { return terminal }
        let components = (path as NSString).pathComponents
        let bundle = components.firstIndex { $0.lowercased().hasSuffix(".app") }
            .map { NSString.path(withComponents: Array(components.prefix($0 + 1))) }
        guard kind == "app" || bundle != nil else { return terminal }
        let appPath = bundle ?? path
        guard FileManager.default.fileExists(atPath: appPath), Bundle(path: appPath) != nil else { return application }
        return NSWorkspace.shared.icon(forFile: appPath)
    }
}

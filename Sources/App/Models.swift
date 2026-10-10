import Foundation

struct ProgramRule: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = ""
    var kind = "cli"
    var pattern = ""
    var mode = "default"
    var zone = "Asia/Tokyo"
    var enabled = true
    var logging = false

    var title: String { name.isEmpty ? (pattern as NSString).lastPathComponent : name }
    var summary: String {
        switch mode {
        case "fixed": return zone.replacingOccurrences(of: "_", with: " ")
        case "ask": return "Ask Every Launch"
        default: return "System Default"
        }
    }
}

struct PolicyDocument: Codable {
    var version = 2
    var es_enabled = false
    var default_mode = "system"
    var default_zone = ""
    var rules: [ProgramRule] = []
}

struct LaunchPrompt: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var path: String
    var zone: String
    var expires_at: Double
    var parent_path: String?
    var parent_pid: Int?
}

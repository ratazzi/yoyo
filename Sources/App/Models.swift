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
    var environment: [String: String] = [:]

    var title: String { name.isEmpty ? (pattern as NSString).lastPathComponent : name }
    var summary: String {
        switch mode {
        case "fixed": return zone.replacingOccurrences(of: "_", with: " ")
        case "ask": return "Ask Every Launch"
        default: return "System Default"
        }
    }
}

extension ProgramRule {
    enum CodingKeys: String, CodingKey { case id, name, kind, pattern, mode, zone, enabled, logging, environment }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(String.self, forKey: .kind)
        pattern = try values.decode(String.self, forKey: .pattern)
        mode = try values.decode(String.self, forKey: .mode)
        zone = try values.decode(String.self, forKey: .zone)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        logging = try values.decode(Bool.self, forKey: .logging)
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
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

import Foundation

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, nightly
    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Nightly" }
    var feedURL: String {
        switch self {
        case .stable: return "https://github.com/ratazzi/yoyo/releases/latest/download/appcast.xml"
        case .nightly: return "https://github.com/ratazzi/yoyo/releases/download/nightly/appcast.xml"
        }
    }

    static func selected(saved: String?, bundled: String?) -> UpdateChannel {
        saved.flatMap(Self.init(rawValue:)) ?? bundled.flatMap(Self.init(rawValue:)) ?? .stable
    }
}
